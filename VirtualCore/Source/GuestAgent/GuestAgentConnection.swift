import Foundation
import Combine
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

    public enum TransferEvent: Sendable {
        /// A frame of the transfer from the agent: its size, an item's header, file data, or an acknowledgement.
        case frame(GuestAgentFrame)
        /// The agent has finished sending files. It's the last event for the channel.
        case filesEnd
        /// The agent put the files it received at these paths. It's the last event for the channel.
        case transferred([String])
        /// The files being dragged in the guest. It's the last event for the channel.
        case dragItems([GuestDragItem])
        /// The transfer couldn't start or didn't finish, or the connection to the agent was lost. It's the last event for the channel.
        case failed(String)
    }

    /// A transfer of files to or from the guest, or a request to catch a drag in it.
    public final class TransferChannel: @unchecked Sendable {
        public let id: UInt32
        fileprivate let handler: @Sendable (TransferEvent) -> Void
        fileprivate weak var connection: GuestAgentConnection?

        fileprivate init(id: UInt32, connection: GuestAgentConnection, handler: @escaping @Sendable (TransferEvent) -> Void) {
            self.id = id
            self.connection = connection
            self.handler = handler
        }

        /// Sends a frame of the transfer. Throws if the connection to the agent is closed.
        public func send(_ kind: GuestAgentFrame.Kind, _ payload: Data = Data()) throws {
            guard let connection else { throw Failure("The connection to the guest agent was lost.") }
            try connection.transport.send(GuestAgentFrame(kind, channel: id, payload: payload))
        }

        /// Cancels the transfer.
        public func cancel() {
            connection?.send(GuestAgentFrame(.terminate, channel: id))
        }
    }

    private enum Endpoint {
        case program(Channel)
        case transfer(TransferChannel)

        func fail(_ message: String) {
            switch self {
            case .program(let channel): channel.handler(.failed(message))
            case .transfer(let channel): channel.handler(.failed(message))
            }
        }
    }

    fileprivate let transport: GuestAgentTransport
    private let logger: Logger
    private let lock = NSLock()
    private var channels = [UInt32: Endpoint]()
    private var nextChannelID: UInt32 = 1
    private var currentInfo: GuestAgentInfo?
    private var isClosed = false

    /// Called on the transport's thread when the agent connects or goes away.
    public var onInfoChange: (@Sendable (GuestAgentInfo?) -> Void)?

    /// What the agent said about itself, or `nil` while it isn't connected, published on the transport's thread.
    public let infoSubject = CurrentValueSubject<GuestAgentInfo?, Never>(nil)

    /// What the agent said about itself, or `nil` while it isn't connected.
    public var info: GuestAgentInfo? {
        lock.withLock { currentInfo }
    }

    /// Whether the agent can copy files and catch drags.
    public var supportsFileTransfers: Bool {
        (info?.protocolVersion ?? 0) >= GuestAgentFrame.fileTransferProtocolVersion
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

            let channel = Channel(id: takeChannelID(), connection: self, handler: handler)
            channels[channel.id] = .program(channel)
            return channel
        }

        send(GuestAgentFrame(.open, channel: channel.id, payload: request.payload))
        return channel
    }

    /// Starts a transfer with ``GuestAgentFrame/Kind/putFiles`` or ``GuestAgentFrame/Kind/getFiles``, or catches a drag with
    /// ``GuestAgentFrame/Kind/catchDrag``. Throws if the agent isn't connected or doesn't support transfers.
    public func openTransfer(_ kind: GuestAgentFrame.Kind, payload: Data = Data(), handler: @escaping @Sendable (TransferEvent) -> Void) throws -> TransferChannel {
        let channel: TransferChannel = try lock.withLock {
            guard !isClosed, let currentInfo else {
                throw Failure("The guest agent isn’t running.")
            }
            guard currentInfo.protocolVersion >= GuestAgentFrame.fileTransferProtocolVersion else {
                throw Failure("The guest agent needs updating to copy files.")
            }

            let channel = TransferChannel(id: takeChannelID(), connection: self, handler: handler)
            channels[channel.id] = .transfer(channel)
            return channel
        }

        do {
            try transport.send(GuestAgentFrame(kind, channel: channel.id, payload: payload))
        } catch {
            _ = lock.withLock { channels.removeValue(forKey: channel.id) }
            throw error
        }
        return channel
    }

    /// Ends a transfer's channel on the Mac's side, such as when it's cancelled, so that nothing more is delivered for it.
    public func forget(_ channel: TransferChannel) {
        _ = lock.withLock { channels.removeValue(forKey: channel.id) }
    }

    /// Must be called with the lock held.
    private func takeChannelID() -> UInt32 {
        defer { nextChannelID = nextChannelID == UInt32.max ? 1 : nextChannelID + 1 }
        return nextChannelID
    }

    public func close() {
        lock.withLock { isClosed = true }
        transport.close()
    }

    /// Asks the agent to start afresh and greet the Mac again, such as when its frames start going over a different link.
    func resetAgent() {
        send(GuestAgentFrame(.reset, channel: 0))
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
            channel.fail("The guest agent disconnected.")
        }
        onInfoChange?(nil)
        infoSubject.send(nil)
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
                    channel.fail("The guest agent restarted.")
                }
                onInfoChange?(info)
                infoSubject.send(info)
            } catch {
                logger.error("Invalid greeting from the guest agent: \(error, privacy: .public)")
            }
        case .output, .errorOutput, .exited, .failed, .transferSize, .fileHeader, .fileData, .filesEnd, .acknowledge, .transferred, .dragItems:
            let isLast = [.exited, .failed, .filesEnd, .transferred, .dragItems].contains(frame.kind)
            let endpoint = lock.withLock {
                isLast ? channels.removeValue(forKey: frame.channel) : channels[frame.channel]
            }

            switch endpoint {
            case .program(let channel):
                switch frame.kind {
                case .output: channel.handler(.output(frame.payload))
                case .errorOutput: channel.handler(.errorOutput(frame.payload))
                case .exited: channel.handler(.exited(frame.exitStatus ?? -1))
                case .failed: channel.handler(.failed(frame.text))
                default: logger.warning("Ignoring a transfer frame of kind \(frame.kind.rawValue) for a program")
                }
            case .transfer(let channel):
                switch frame.kind {
                case .failed: channel.handler(.failed(frame.text))
                case .filesEnd: channel.handler(.filesEnd)
                case .transferred: channel.handler(.transferred(frame.pathList))
                case .dragItems: channel.handler(.dragItems(GuestDragItem.items(from: frame.payload)))
                case .transferSize, .fileHeader, .fileData, .acknowledge: channel.handler(.frame(frame))
                default: logger.warning("Ignoring a program frame of kind \(frame.kind.rawValue) for a transfer")
                }
            case nil:
                break
            }
        case .reset, .open, .input, .inputEnd, .resize, .terminate, .putFiles, .getFiles, .catchDrag:
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
            channel.fail("The connection to the guest agent was lost.")
        }
        onInfoChange?(nil)
        infoSubject.send(nil)
    }
}

/// Passes on what the agent says about itself, across the connections that come and go as a virtual machine starts and stops.
final class GuestAgentInfoRelay: @unchecked Sendable {
    private let subject = CurrentValueSubject<GuestAgentInfo?, Never>(nil)
    private let lock = NSLock()
    private var observation: AnyCancellable?

    var publisher: AnyPublisher<GuestAgentInfo?, Never> { subject.eraseToAnyPublisher() }

    func attach(_ connection: GuestAgentConnection) {
        let observation = connection.infoSubject.sink { [subject] in subject.send($0) }
        lock.withLock { self.observation = observation }
    }

    func detach() {
        lock.withLock { observation = nil }
        subject.send(nil)
    }
}

/// Whether the Hypervisaur agent in a Windows or Linux guest is connected, and whether it's new enough to copy files.
/// In macOS guests, the agent is part of the guest app, whose status is ``GuestAppConnectionStatus``.
public enum GuestAgentStatus: Equatable, Sendable {
    case connected(GuestAgentInfo)
    /// Connected, but too old to copy files.
    case outdated(GuestAgentInfo)
    case disconnected

    public init(info: GuestAgentInfo?) {
        guard let info else {
            self = .disconnected
            return
        }
        self = info.protocolVersion >= GuestAgentFrame.fileTransferProtocolVersion ? .connected(info) : .outdated(info)
    }
}
