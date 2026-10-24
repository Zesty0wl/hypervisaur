import Foundation
import VirtualWormhole
import OSLog

/// Carries frames to and from the agent in a guest.
public protocol GuestAgentTransport: AnyObject, Sendable {
    /// Starts receiving frames. `onClose` is called once, when the transport closes or fails.
    func start(onFrame: @escaping @Sendable (GuestAgentFrame) -> Void, onClose: @escaping @Sendable (Error?) -> Void)
    func send(_ frame: GuestAgentFrame) throws
    func close()
}

/// A transport over a stream of bytes, such as a serial port that QEMU or Virtualization connects to the guest.
final class GuestAgentStreamTransport: GuestAgentTransport, @unchecked Sendable {
    private let readAvailable: () throws -> Data?
    private let write: (Data) throws -> Void
    private let closeStream: () -> Void
    private let name: String

    init(name: String, readAvailable: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void, close: @escaping () -> Void) {
        self.name = name
        self.readAvailable = readAvailable
        self.write = write
        self.closeStream = close
    }

    convenience init(name: String, socket: UnixSocketConnection) {
        self.init(
            name: name,
            readAvailable: { try socket.readAvailable(maxLength: 64 * 1024) },
            write: { try socket.write($0) },
            close: { socket.close() }
        )
    }

    func start(onFrame: @escaping @Sendable (GuestAgentFrame) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        let thread = Thread { [readAvailable] in
            var decoder = GuestAgentFrameDecoder()
            do {
                while let data = try readAvailable() {
                    for frame in try decoder.decode(data) {
                        onFrame(frame)
                    }
                }
                onClose(nil)
            } catch {
                onClose(error)
            }
        }
        thread.name = name
        thread.start()
    }

    func send(_ frame: GuestAgentFrame) throws {
        try write(frame.encoded())
    }

    func close() {
        closeStream()
    }
}

/// The connection to the agent in a running guest, which runs programs there.
///
/// Programs run on channels of their own, so that any number can run at once. Events for a channel are delivered on
/// the transport's thread, in the order the agent sent them.
public final class GuestAgentConnection: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case output(Data)
        case errorOutput(Data)
        /// The program exited with this status. It's the last event for the channel.
        case exited(Int32)
        /// The program couldn't be started, or the connection to the agent was lost. It's the last event for the channel.
        case failed(String)
    }

    /// A program that the agent is running.
    public final class Channel: @unchecked Sendable {
        public let id: UInt32
        fileprivate let handler: @Sendable (Event) -> Void
        fileprivate weak var connection: GuestAgentConnection?

        fileprivate init(id: UInt32, connection: GuestAgentConnection, handler: @escaping @Sendable (Event) -> Void) {
            self.id = id
            self.connection = connection
            self.handler = handler
        }

        public func send(_ input: Data) {
            for start in stride(from: 0, to: input.count, by: GuestAgentFrame.preferredChunkSize) {
                let end = min(start + GuestAgentFrame.preferredChunkSize, input.count)
                connection?.send(GuestAgentFrame(.input, channel: id, payload: input.subdata(in: start..<end)))
            }
        }

        public func endInput() {
            connection?.send(GuestAgentFrame(.inputEnd, channel: id))
        }

        public func resize(columns: UInt16, rows: UInt16) {
            connection?.send(GuestAgentFrame(.resize, channel: id, payload: GuestAgentFrame.terminalSize(columns: columns, rows: rows)))
        }

        public func terminate() {
            connection?.send(GuestAgentFrame(.terminate, channel: id))
        }
    }

    private let transport: GuestAgentTransport
    private let logger: Logger
    private let lock = NSLock()
    private var channels = [UInt32: Channel]()
    private var nextChannelID: UInt32 = 1
    private var currentInfo: GuestAgentInfo?
    private var isClosed = false

    /// Called on the transport's thread when the agent connects or goes away.
    public var onInfoChange: (@Sendable (GuestAgentInfo?) -> Void)?

    /// What the agent said about itself, or `nil` while it isn't connected.
    public var info: GuestAgentInfo? {
        lock.withLock { currentInfo }
    }

    public init(transport: GuestAgentTransport, guestName: String) {
        self.transport = transport
        self.logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "GuestAgent(\(guestName))")
    }

    /// Starts talking to the agent, which replies once it's running in the guest.
    public func start() {
        transport.start { [weak self] frame in
            self?.handle(frame)
        } onClose: { [weak self] error in
            self?.handleClose(error)
        }

        send(GuestAgentFrame(.reset, channel: 0))
    }

    /// Runs a program in the guest. Throws if the agent isn't connected.
    public func open(_ request: GuestAgentOpenRequest, handler: @escaping @Sendable (Event) -> Void) throws -> Channel {
        let channel: Channel = try lock.withLock {
            guard !isClosed, currentInfo != nil else {
                throw Failure("The guest agent isn’t running.")
            }

            let channel = Channel(id: nextChannelID, connection: self, handler: handler)
            nextChannelID = nextChannelID == UInt32.max ? 1 : nextChannelID + 1
            channels[channel.id] = channel
            return channel
        }

        send(GuestAgentFrame(.open, channel: channel.id, payload: request.payload))
        return channel
    }

    public func close() {
        lock.withLock { isClosed = true }
        transport.close()
    }

    /// The agent can't be reached for now, such as when a guest app has quit, so what it was running has stopped.
    /// It greets the Mac again when it can be reached.
    public func agentDisconnected() {
        let interrupted = lock.withLock {
            let wasConnected = currentInfo != nil
            currentInfo = nil
            defer { channels.removeAll() }
            return wasConnected || !channels.isEmpty ? Array(channels.values) : nil
        }
        guard let interrupted else { return }

        for channel in interrupted {
            channel.handler(.failed("The guest agent disconnected."))
        }
        onInfoChange?(nil)
    }

    private func send(_ frame: GuestAgentFrame) {
        do {
            try transport.send(frame)
        } catch {
            logger.error("Failed to send to the guest agent: \(error, privacy: .public)")
        }
    }

    private func handle(_ frame: GuestAgentFrame) {
        switch frame.kind {
        case .hello:
            do {
                let info = try GuestAgentInfo(payload: frame.payload)
                logger.notice("Guest agent connected: \(info.system, privacy: .public), protocol \(info.protocolVersion)")

                /// The agent says hello again when it starts afresh, which ends whatever it was running.
                let interrupted = lock.withLock {
                    currentInfo = info
                    defer { channels.removeAll() }
                    return Array(channels.values)
                }
                for channel in interrupted {
                    channel.handler(.failed("The guest agent restarted."))
                }
                onInfoChange?(info)
            } catch {
                logger.error("Invalid greeting from the guest agent: \(error, privacy: .public)")
            }
        case .output, .errorOutput, .exited, .failed:
            let channel = lock.withLock {
                frame.kind == .exited || frame.kind == .failed ? channels.removeValue(forKey: frame.channel) : channels[frame.channel]
            }
            guard let channel else { return }

            switch frame.kind {
            case .output: channel.handler(.output(frame.payload))
            case .errorOutput: channel.handler(.errorOutput(frame.payload))
            case .exited: channel.handler(.exited(frame.exitStatus ?? -1))
            default: channel.handler(.failed(frame.text))
            }
        case .reset, .open, .input, .inputEnd, .resize, .terminate:
            logger.warning("Ignoring unexpected frame of kind \(frame.kind.rawValue) from the guest agent")
        }
    }

    private func handleClose(_ error: Error?) {
        if let error {
            logger.error("Lost the connection to the guest agent: \(error, privacy: .public)")
        }

        let interrupted = lock.withLock {
            isClosed = true
            currentInfo = nil
            defer { channels.removeAll() }
            return Array(channels.values)
        }
        for channel in interrupted {
            channel.handler(.failed("The connection to the guest agent was lost."))
        }
        onInfoChange?(nil)
    }
}
