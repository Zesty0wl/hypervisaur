import Foundation
import Darwin
import OSLog

/// A peer-to-peer D-Bus connection over a Unix domain socket, such as the ones QEMU's D-Bus display serves.
///
/// Hypervisaur is always the client in the connection's authentication, which uses the `EXTERNAL` mechanism: the peer
/// checks who's on the other end of the socket. File descriptors can be passed both ways. There's no message bus, so
/// messages have no destination. Messages are read on a thread of their own, which method calls from the peer are
/// handled on.
final class DBusConnection: @unchecked Sendable {
    enum MethodResult {
        case reply([DBusValue])
        case error(name: String, message: String)

        static func unknownMethod(_ call: DBusMessage) -> MethodResult {
            .error(
                name: "org.freedesktop.DBus.Error.UnknownMethod",
                message: "\(call.interface ?? "").\(call.member ?? "") isn’t implemented at \(call.path ?? "")."
            )
        }

        static func invalidArguments(_ message: String) -> MethodResult {
            .error(name: "org.freedesktop.DBus.Error.InvalidArgs", message: message)
        }
    }

    /// Handles a method call from the peer, on the thread that reads messages.
    typealias MethodHandler = (DBusMessage) -> MethodResult

    /// The longest line that's accepted while authenticating.
    private static let maximumAuthenticationLineLength = 16_384

    /// The most file descriptors that are accepted with each read from the socket.
    private static let maximumDescriptorsPerRead = 32

    private let name: String
    private let logger: Logger
    private let socket: OwnedFileDescriptor
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var nextSerial: UInt32 = 1
    private var pendingCalls = [UInt32: CheckedContinuation<DBusMessage, Error>]()
    private var isClosed = false

    /// - Parameter socket: A connected stream socket, which the connection takes over.
    init(socket: OwnedFileDescriptor, name: String) {
        self.socket = socket
        self.name = name
        self.logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "DBusConnection(\(name))")

        var noSigPipe: Int32 = 1
        setsockopt(socket.rawValue, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: - Authentication

    /// Authenticates with the peer, and agrees to pass file descriptors. Messages can be sent and received afterwards.
    func authenticate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread { [self] in
                do {
                    try performAuthentication()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performAuthentication() throws {
        /// Every connection starts with a null byte, which is where credentials would be passed on systems that pass them.
        try write(Data([0]), passing: [])

        let userID = Data(String(getuid()).utf8).map { String(format: "%02x", $0) }.joined()
        try writeLine("AUTH EXTERNAL \(userID)")

        let reply = try readLine()
        guard reply.hasPrefix("OK ") else { throw DBusError.authenticationFailed(reply) }

        try writeLine("NEGOTIATE_UNIX_FD")

        let agreement = try readLine()
        guard agreement == "AGREE_UNIX_FD" else {
            throw DBusError.authenticationFailed("The peer can’t pass file descriptors: \(agreement)")
        }

        try writeLine("BEGIN")
    }

    private func writeLine(_ line: String) throws {
        try write(Data((line + "\r\n").utf8), passing: [])
    }

    /// Reads a line one byte at a time, so that nothing after it is read before messages are.
    private func readLine() throws -> String {
        var line = Data()

        while line.suffix(2) != Data("\r\n".utf8) {
            guard line.count < Self.maximumAuthenticationLineLength else {
                throw DBusError.authenticationFailed("The peer sent a line that’s too long.")
            }

            var byte: UInt8 = 0
            let result = Darwin.read(socket.rawValue, &byte, 1)
            if result == 1 {
                line.append(byte)
            } else if result == 0 {
                throw DBusError.connectionClosed
            } else if errno != EINTR {
                throw POSIXError.current
            }
        }

        return String(decoding: line.dropLast(2), as: UTF8.self)
    }

    // MARK: - Messages

    /// Starts reading messages from the peer, once the connection is authenticated.
    ///
    /// - Parameters:
    ///   - handler: Handles method calls from the peer. Without one, they're answered with an error.
    ///   - onClose: Called once, on the thread that reads messages, when the connection ends.
    func start(handlingMethodCallsWith handler: MethodHandler? = nil, onClose: @escaping (Error?) -> Void) {
        let thread = Thread { [self] in
            var closingError: Error?
            do {
                try receiveMessages(handler: handler)
            } catch {
                closingError = error
                if !lock.withLock({ isClosed }) {
                    logger.error("The connection failed: \(error, privacy: .public)")
                }
            }

            close()
            onClose(closingError)
        }
        thread.name = "DBusConnection(\(name))"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Calls a method of an object that the peer has, and returns the reply.
    ///
    /// - Throws: ``DBusError/remote(name:message:)`` if the peer replies with an error.
    @discardableResult
    func call(
        path: String,
        interface: String,
        member: String,
        body: [DBusValue] = [],
        fileDescriptors: [OwnedFileDescriptor] = []
    ) async throws -> DBusMessage {
        var message = DBusMessage.methodCall(path: path, interface: interface, member: member, body: body, fileDescriptors: fileDescriptors)

        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DBusMessage, Error>) in
            let serial: UInt32? = lock.withLock {
                guard !isClosed else { return nil }
                let serial = takeSerial()
                pendingCalls[serial] = continuation
                return serial
            }

            guard let serial else {
                continuation.resume(throwing: DBusError.connectionClosed)
                return
            }

            message.serial = serial

            do {
                try write(message.encoded(), passing: message.fileDescriptors)
            } catch {
                let pending = lock.withLock { pendingCalls.removeValue(forKey: serial) }
                pending?.resume(throwing: error)
            }
        }

        if reply.kind == .error {
            throw DBusError.remote(name: reply.errorName ?? "", message: reply.errorMessage)
        }

        return reply
    }

    /// Sends a message that no reply is waited for, such as the reply to a method call.
    func send(_ message: DBusMessage) throws {
        var message = message
        message.serial = try lock.withLock {
            guard !isClosed else { throw DBusError.connectionClosed }
            return takeSerial()
        }

        try write(message.encoded(), passing: message.fileDescriptors)
    }

    /// Ends the connection, which fails the calls that are waiting for replies and stops reading messages.
    func close() {
        let pending: [CheckedContinuation<DBusMessage, Error>] = lock.withLock {
            isClosed = true
            defer { pendingCalls.removeAll() }
            return Array(pendingCalls.values)
        }

        shutdown(socket.rawValue, SHUT_RDWR)

        for continuation in pending {
            continuation.resume(throwing: DBusError.connectionClosed)
        }
    }

    private func takeSerial() -> UInt32 {
        let serial = nextSerial
        nextSerial = nextSerial == .max ? 1 : nextSerial + 1
        return serial
    }

    private func receiveMessages(handler: MethodHandler?) throws {
        var buffer = Data()
        var descriptors = [OwnedFileDescriptor]()

        while true {
            while buffer.count >= DBusMessage.fixedHeaderLength {
                let length = try DBusMessage.length(fromFixedHeader: buffer.prefix(DBusMessage.fixedHeaderLength))
                guard buffer.count >= length else { break }

                let message = try DBusMessage.decode(buffer.prefix(length)) { count in
                    guard count <= descriptors.count else {
                        throw DBusError.malformedMessage("A message came with fewer file descriptors than it says.")
                    }
                    defer { descriptors.removeFirst(count) }
                    return Array(descriptors.prefix(count))
                }
                buffer = Data(buffer.dropFirst(length))

                dispatch(message, handler: handler)
            }

            guard try receive(into: &buffer, descriptors: &descriptors) else { return }
        }
    }

    private func dispatch(_ message: DBusMessage, handler: MethodHandler?) {
        switch message.kind {
        case .methodReturn, .error:
            guard let replySerial = message.replySerial else { return }
            let continuation = lock.withLock { pendingCalls.removeValue(forKey: replySerial) }
            continuation?.resume(returning: message)
        case .methodCall:
            let result = handler?(message) ?? .unknownMethod(message)

            guard !message.flags.contains(.noReplyExpected) else { return }

            let reply = switch result {
            case .reply(let body): message.reply(body)
            case .error(let name, let text): message.errorReply(name: name, message: text)
            }

            do {
                try send(reply)
            } catch {
                logger.debug("Couldn't reply to \(message.member ?? "", privacy: .public): \(error, privacy: .public)")
            }
        case .signal:
            break
        }
    }

    // MARK: - Socket

    /// Reads whatever is available, with the file descriptors that came with it.
    /// - Returns: `false` once the peer has closed the connection.
    private func receive(into buffer: inout Data, descriptors: inout [OwnedFileDescriptor]) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 65_536)

        let count = try bytes.withUnsafeMutableBytes { bytesBuffer in
            try SocketControlMessage.receive(
                into: bytesBuffer,
                descriptors: &descriptors,
                maximumDescriptors: Self.maximumDescriptorsPerRead,
                on: socket.rawValue
            )
        }

        guard count > 0 else { return false }

        buffer.append(contentsOf: bytes[0..<count])
        return true
    }

    private func write(_ data: Data, passing descriptors: [OwnedFileDescriptor]) throws {
        try writeLock.withLock {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }

                /// The descriptors go with the first part that's written.
                var offset = descriptors.isEmpty ? 0 : try SocketControlMessage.send(buffer, passing: descriptors.map(\.rawValue), on: socket.rawValue)

                while offset < buffer.count {
                    let result = Darwin.write(socket.rawValue, base.advanced(by: offset), buffer.count - offset)
                    if result >= 0 {
                        offset += result
                    } else if errno != EINTR {
                        throw POSIXError.current
                    }
                }
            }
        }
    }
}
