import Foundation
import VirtualWormhole
import CryptoKit
import OSLog
import os

/// Lets programs on the Mac, such as `hvctl` and `vbmcp`, run programs in a guest through its agent while the virtual machine runs.
///
/// It listens on a Unix socket that only the user can reach, at a path that's derived from the virtual machine's bundle,
/// so that those programs can find it without asking Hypervisaur. Each connection runs one program: the client sends
/// ``GuestAgentFrame/Kind/open`` and then its input on channel 1, and receives the program's output on the same channel,
/// until it exits.
public final class GuestAgentServer: @unchecked Sendable {
    static let clientChannel: UInt32 = 1

    public let socketURL: URL

    private let connection: GuestAgentConnection
    private let unavailableMessage: @Sendable () -> String
    private let listeningSocket: Int32
    private let logger: Logger
    private let lock = NSLock()
    private var clients = [ObjectIdentifier: UnixSocketConnection]()
    private var isClosed = false

    /// The socket for a virtual machine. It's in the user's temporary directory, since socket paths are limited to 104 bytes,
    /// which is taken from the system rather than the environment, so that programs with a different `TMPDIR` find it too.
    public static func socketURL(forVirtualMachineAt bundleURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(bundleURL.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        return userTemporaryDirectory
            .appending(path: "hypervisaur-agent", directoryHint: .isDirectory)
            .appending(path: "\(name).sock")
    }

    private static var userTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            return FileManager.default.temporaryDirectory
        }
        return URL(filePath: String(cString: buffer), directoryHint: .isDirectory)
    }

    /// - Parameter unavailableMessage: Explains how to get the agent running, for when a program can't be run because it isn't.
    public init(connection: GuestAgentConnection, socketURL: URL, guestName: String, unavailableMessage: @escaping @Sendable () -> String) throws {
        self.connection = connection
        self.socketURL = socketURL
        self.unavailableMessage = unavailableMessage
        self.logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "GuestAgentServer(\(guestName))")

        let directoryURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: socketURL)

        listeningSocket = try Self.listen(at: socketURL.path)
    }

    private static func listen(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure("Socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            let error = POSIXError.current
            Darwin.close(fd)
            throw error
        }

        return fd
    }

    public func start() {
        let thread = Thread { [weak self, listeningSocket] in
            while true {
                let clientSocket = accept(listeningSocket, nil, nil)
                guard clientSocket >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                guard let self else {
                    Darwin.close(clientSocket)
                    return
                }
                self.serve(UnixSocketConnection(fileDescriptor: clientSocket))
            }
        }
        thread.name = "GuestAgentServer"
        thread.start()
    }

    public func close() {
        let openClients = lock.withLock {
            isClosed = true
            defer { clients.removeAll() }
            return Array(clients.values)
        }

        shutdown(listeningSocket, SHUT_RDWR)
        Darwin.close(listeningSocket)
        try? FileManager.default.removeItem(at: socketURL)

        for client in openClients {
            client.close()
        }
    }

    private func serve(_ client: UnixSocketConnection) {
        let isAccepted = lock.withLock {
            guard !isClosed else { return false }
            clients[ObjectIdentifier(client)] = client
            return true
        }
        guard isAccepted else {
            client.close()
            return
        }

        let thread = Thread { [weak self] in
            self?.relay(client)
            self?.lock.withLock { _ = self?.clients.removeValue(forKey: ObjectIdentifier(client)) }
            client.close()
        }
        thread.name = "GuestAgentServer client"
        thread.start()
    }

    /// Runs the client's program, passing its input to the agent until the client goes away or the program exits.
    private func relay(_ client: UnixSocketConnection) {
        var decoder = GuestAgentFrameDecoder()
        var channel: GuestAgentConnection.Channel?

        @Sendable func reply(_ kind: GuestAgentFrame.Kind, _ payload: Data = Data()) {
            try? client.write(GuestAgentFrame(kind, channel: Self.clientChannel, payload: payload).encoded())
        }

        defer { channel?.terminate() }

        do {
            while let data = try client.readAvailable(maxLength: 64 * 1024) {
                for frame in try decoder.decode(data) where frame.channel == Self.clientChannel {
                    switch frame.kind {
                    case .open:
                        guard channel == nil else { continue }
                        let request = try GuestAgentOpenRequest(payload: frame.payload)

                        do {
                            channel = try connection.open(request) { event in
                                switch event {
                                case .output(let data): reply(.output, data)
                                case .errorOutput(let data): reply(.errorOutput, data)
                                case .exited(let status): reply(.exited, GuestAgentFrame.exitStatus(status))
                                case .failed(let message): reply(.failed, Data(message.utf8))
                                }

                                switch event {
                                case .exited, .failed: client.close()
                                case .output, .errorOutput: break
                                }
                            }
                        } catch {
                            reply(.failed, Data(unavailableMessage().utf8))
                            return
                        }
                    case .input:
                        channel?.send(frame.payload)
                    case .inputEnd:
                        channel?.endInput()
                    case .resize:
                        if let size = frame.terminalSize {
                            channel?.resize(columns: size.columns, rows: size.rows)
                        }
                    case .terminate:
                        channel?.terminate()
                    case .reset, .hello, .output, .errorOutput, .exited, .failed:
                        break
                    }
                }
            }
        } catch {
            logger.debug("Client connection ended: \(error, privacy: .public)")
        }
    }
}

/// Runs a program in a guest through Hypervisaur, from another program on the Mac.
public final class GuestAgentClient: @unchecked Sendable {
    private let socket: UnixSocketConnection
    private var decoder = GuestAgentFrameDecoder()
    private var pendingEvents = [GuestAgentConnection.Event]()

    /// Connects to the virtual machine, which needs to be running in Hypervisaur.
    public init(virtualMachineAt bundleURL: URL, name: String) throws {
        let socketURL = GuestAgentServer.socketURL(forVirtualMachineAt: bundleURL)
        do {
            socket = try UnixSocketConnection(path: socketURL.path)
        } catch {
            throw Failure("“\(name)” isn’t running in Hypervisaur, or doesn’t have a guest agent.")
        }
    }

    /// Starts the program. Its events are read with ``nextEvent()``.
    public func open(_ request: GuestAgentOpenRequest) throws {
        try send(GuestAgentFrame(.open, channel: GuestAgentServer.clientChannel, payload: request.payload))
    }

    public func send(input: Data) throws {
        for start in stride(from: 0, to: input.count, by: GuestAgentFrame.preferredChunkSize) {
            let end = min(start + GuestAgentFrame.preferredChunkSize, input.count)
            try send(GuestAgentFrame(.input, channel: GuestAgentServer.clientChannel, payload: input.subdata(in: start..<end)))
        }
    }

    public func endInput() throws {
        try send(GuestAgentFrame(.inputEnd, channel: GuestAgentServer.clientChannel))
    }

    public func resize(columns: UInt16, rows: UInt16) throws {
        try send(GuestAgentFrame(.resize, channel: GuestAgentServer.clientChannel, payload: GuestAgentFrame.terminalSize(columns: columns, rows: rows)))
    }

    public func terminate() throws {
        try send(GuestAgentFrame(.terminate, channel: GuestAgentServer.clientChannel))
    }

    /// Stops reading, which makes a blocked ``nextEvent()`` return.
    public func close() {
        socket.close()
    }

    /// Waits for the program's next event. Returns `nil` once there are no more, after it has exited.
    /// Events are read from one thread at a time.
    public func nextEvent() throws -> GuestAgentConnection.Event? {
        while pendingEvents.isEmpty {
            guard let data = try socket.readAvailable(maxLength: 64 * 1024) else { return nil }

            for frame in try decoder.decode(data) where frame.channel == GuestAgentServer.clientChannel {
                switch frame.kind {
                case .output: pendingEvents.append(.output(frame.payload))
                case .errorOutput: pendingEvents.append(.errorOutput(frame.payload))
                case .exited: pendingEvents.append(.exited(frame.exitStatus ?? -1))
                case .failed: pendingEvents.append(.failed(frame.text))
                default: break
                }
            }
        }
        return pendingEvents.removeFirst()
    }

    private func send(_ frame: GuestAgentFrame) throws {
        try socket.write(frame.encoded())
    }
}

/// What a program that ran in a guest printed, and how it exited.
public struct GuestAgentCommandResult: Sendable {
    public var output: Data
    public var errorOutput: Data
    public var status: Int32
    /// Whether the program was stopped because it took too long.
    public var timedOut = false
    /// Whether some of the output was dropped because there was too much.
    public var isTruncated = false

    public init(output: Data, errorOutput: Data, status: Int32, timedOut: Bool = false, isTruncated: Bool = false) {
        self.output = output
        self.errorOutput = errorOutput
        self.status = status
        self.timedOut = timedOut
        self.isTruncated = isTruncated
    }
}

public extension GuestAgentClient {
    /// Runs a command in the guest and waits for it to finish, stopping it if it takes longer than the timeout.
    /// Output beyond `outputLimit` bytes is dropped.
    static func run(_ command: String, inVirtualMachineAt bundleURL: URL, name: String, timeout: Duration, outputLimit: Int = 1 << 20) async throws -> GuestAgentCommandResult {
        let client = try GuestAgentClient(virtualMachineAt: bundleURL, name: name)
        try client.open(GuestAgentOpenRequest(command: command))
        try client.endInput()

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            try? client.terminate()
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                var output = Data()
                var errorOutput = Data()
                var isTruncated = false

                func append(_ data: Data, to buffer: inout Data) {
                    let kept = data.prefix(max(0, outputLimit - buffer.count))
                    isTruncated = isTruncated || kept.count < data.count
                    buffer.append(kept)
                }

                do {
                    while let event = try client.nextEvent() {
                        switch event {
                        case .output(let data):
                            append(data, to: &output)
                        case .errorOutput(let data):
                            append(data, to: &errorOutput)
                        case .exited(let status):
                            client.close()
                            continuation.resume(returning: GuestAgentCommandResult(
                                output: output,
                                errorOutput: errorOutput,
                                status: status,
                                timedOut: timedOut.withLock { $0 },
                                isTruncated: isTruncated
                            ))
                            return
                        case .failed(let message):
                            client.close()
                            continuation.resume(throwing: Failure(message))
                            return
                        }
                    }
                    continuation.resume(throwing: Failure("“\(name)” stopped before the command finished."))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "GuestAgentClient"
            thread.start()
        }
    }
}
