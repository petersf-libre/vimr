/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Foundation
import RxSwift
import MessagePack
import Socket

public final class RxMsgpackRpc {

  public typealias Value = MessagePackValue

  enum MessageType: UInt64 {

    case request = 0
    case response = 1
    case notification = 2
  }

  public enum Message {

    case response(msgid: UInt32, error: Value, result: Value)
    case notification(method: String, params: [Value])
    case error(value: Value, msg: String)
  }

  public struct Response {

    public let msgid: UInt32
    public let error: Value
    public let result: Value
  }

  public struct Error: Swift.Error {

    var msg: String
    var cause: Swift.Error?

    init(msg: String, cause: Swift.Error? = nil) {
      self.msg = msg
      self.cause = cause
    }
  }

  /**
   Streams `Message.notification`s and `Message.error`s by default.
   When `streamResponses` is set to `true`, then also `Message.response`s.
  */
  public var stream: Observable<Message> {
    return self.streamSubject.asObservable()
  }

  /**
   When `true`, all messages of type `MessageType.response` are also streamed
   to `stream` as `Message.response`. When `false`, only the `Single`s
   you get from `request(msgid, method, params, expectsReturnValue)` will
   get the response as `Response`.
  */
  public var streamResponses = false

  public var queue = DispatchQueue(
    label: String(reflecting: RxMsgpackRpc.self),
    qos: .userInitiated
  )

  private var socket: Socket?
  private var thread: Thread?

  public init() {
  }

  public func run(at path: String) -> Completable {
    return Completable.create { completable in
      self.queue.async {
        self.stopLock.withWriteLock {
          self.stopped = false

          do {
            try self.socket = Socket.create(
              family: .unix,
              type: .stream,
              proto: .unix
            )
            try self.socket?.connect(to: path)
            self.setUpThreadAndStartReading()
          } catch {
            self.streamSubject.onError(
              Error(msg: "Could not get socket", cause: error)
            )
            completable(.error(
              Error(msg: "Could not get socket at \(path)", cause: error)
            ))
          }
        }

        completable(.completed)
      }

      return Disposables.create()
    }
  }

  public func stop() -> Completable {
    return Completable.create { completable in
      self.queue.async {
        self.stopLock.withWriteLock {
          self.streamSubject.onCompleted()
          self.cleanUpAndCloseSocket()

          completable(.completed)
        }
      }
      return Disposables.create()
    }
  }

  public func request(
    method: String,
    params: [Value],
    expectsReturnValue: Bool
  ) -> Single<Response> {

    return Single.create { single in
      self.queue.async {
        let msgid: UInt32 = self.nextMsgidLock.withLock {
          let result = self.nextMsgid
          self.nextMsgid += 1
          return result
        }

        let packed = pack(
          [
            .uint(MessageType.request.rawValue),
            .uint(UInt64(msgid)),
            .string(method),
            .array(params),
          ]
        )

        self.stopLock.withReadLock {
          if self.stopped {
            single(.error(Error(msg: "Connection stopped, " +
              "but trying to send a request with msg id \(msgid)")))
            return
          }

          guard let socket = self.socket else {
            single(.error(Error(msg: "Socket is invalid, " +
              "but trying to send a request with msg id \(msgid)")))
            return
          }

          if expectsReturnValue {
            self.singlesLock.withLock {
              self.singles[msgid] = single
            }
          }

          do {
            let writtenBytes = try socket.write(from: packed)
            if writtenBytes < packed.count {
              single(.error(Error(
                msg: "(Written) = \(writtenBytes) < \(packed.count) = " +
                  "(requested) for msg id: \(msgid)"
              )))

              return
            }
          } catch {
            self.streamSubject.onError(Error(
              msg: "Could not write to socket for msg id: " +
                "\(msgid)", cause: error))

            single(.error(Error(
              msg: "Could not write to socket for msg id: " +
                "\(msgid)", cause: error)))

            return
          }

          if !expectsReturnValue {
            single(.success(self.nilResponse(with: msgid)))
          }
        }
      }

      return Disposables.create()
    }
  }

  private var nextMsgid: UInt32 = 0
  private let nextMsgidLock = NSLock()

  private var stopped = true
  private let stopLock = ReadersWriterLock()

  private let streamSubject = PublishSubject<Message>()

  private var singles: [UInt32: SingleResponseObserver] = [:]
  private let singlesLock = NSLock()

  private func nilResponse(with msgid: UInt32) -> Response {
    return Response(msgid: msgid, error: .nil, result: .nil)
  }

  private func cleanUpAndCloseSocket() {
    self.singlesLock.withLock {
      self.singles.forEach { msgid, single in
        single(.success(self.nilResponse(with: msgid)))
      }
    }
    self.singles.removeAll()

    self.stopped = true
    self.socket?.close()
  }

  private func setUpThreadAndStartReading() {
    self.thread = Thread {
      guard let socket = self.socket else {
        return
      }

      var readData = Data(capacity: 10240)
      repeat {
        do {
          let readBytes = try socket.read(into: &readData)
          defer { readData.count = 0 }
          if readBytes > 0 {
            let values = try unpackAll(readData)
            values.forEach(self.processMessage)
          }
        } catch let error as Socket.Error {
          self.streamSubject.onError(Error(
            msg: "Could not read from socket", cause: error)
          )
          // No need to lock since we are currently trying to open the socket.
          self.cleanUpAndCloseSocket()
          return
        } catch {
          self.streamSubject.onNext(
            .error(value: .nil, msg: "Data from socket could not be unpacked")
          )
          return
        }
      } while !self.stopped
    }
    self.thread?.start()
  }

  private func processMessage(_ unpacked: Value) {
    guard let array = unpacked.arrayValue else {
      self.streamSubject.onNext(.error(
        value: unpacked,
        msg: "Could not get the array from the message"
      ))
      return
    }

    guard let rawType = array[0].uint64Value,
          let type = MessageType(rawValue: rawType)
      else {
      self.streamSubject.onNext(.error(
        value: unpacked, msg: "Could not get the type of the message"
      ))
      return
    }

    switch type {

    case .response:
      guard array.count == 4 else {
        self.streamSubject.onNext(.error(
          value: unpacked,
          msg: "Got an array of length \(array.count) " +
            "for a message type response"
        ))
        return
      }

      guard let msgid64 = array[1].uint64Value else {
        self.streamSubject.onNext(.error(
          value: unpacked,
          msg: "Could not get the msgid"
        ))
        return
      }
      self.processResponse(
        msgid: UInt32(msgid64),
        error: array[2],
        result: array[3]
      )

    case .notification:
      guard array.count == 3 else {
        self.streamSubject.onNext(.error(
          value: unpacked,
          msg: "Got an array of length \(array.count) " +
            "for a message type notification"
        ))

        return
      }

      guard let method = array[1].stringValue,
            let params = array[2].arrayValue
        else {
        self.streamSubject.onNext(.error(
          value: unpacked,
          msg: "Could not get the method and params"
        ))
        return
      }

      self.streamSubject.onNext(.notification(method: method, params: params))

    case .request:
      self.streamSubject.onNext(.error(
        value: unpacked,
        msg: "Got message type request from remote"
      ))
      return
    }
  }

  private func processResponse(msgid: UInt32, error: Value, result: Value) {
    if self.streamResponses {
      self.streamSubject.onNext(.response(
        msgid: msgid,
        error: error,
        result: result
      ))
    }

    guard let single: SingleResponseObserver = self.singlesLock.withLock({
      let s = self.singles[msgid]
      self.singles.removeValue(forKey: msgid)
      return s
    }) else {
      return
    }

    single(.success(Response(msgid: msgid, error: error, result: result)))
  }
}

private typealias SingleResponseObserver
  = (SingleEvent<RxMsgpackRpc.Response>) -> Void

fileprivate extension NSLocking {

  @discardableResult
  func withLock<T>(_ body: () -> T) -> T {
    self.lock()
    defer { self.unlock() }
    return body()
  }
}
