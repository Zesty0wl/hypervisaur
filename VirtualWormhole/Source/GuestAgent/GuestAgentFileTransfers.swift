import Foundation
import OSLog

/// The macOS agent's file transfers: files the Mac puts on the desktop, files it gets from the guest, and drags it catches.
final class GuestAgentFileTransfers: @unchecked Sendable {
    /// Finds out which files are being dragged in the guest. The guest app provides it, since it needs a window.
    typealias DragCatcher = @MainActor @Sendable () async -> [GuestDragItem]

    private let send: @Sendable (GuestAgentFrame) -> Void
    private let logger = Logger(subsystem: VirtualWormholeConstants.subsystemName, category: "GuestAgentFileTransfers")
    private let lock = NSLock()
    private var incoming = [UInt32: IncomingTransfer]()
    private var outgoing = [UInt32: GuestFileSender]()
    private var catcher: DragCatcher?
    private let desktopURL: @Sendable () throws -> URL

    /// - Parameter desktopURL: Where files the Mac sends are put, which is the user's desktop.
    init(
        desktopURL: @escaping @Sendable () throws -> URL = { try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true) },
        send: @escaping @Sendable (GuestAgentFrame) -> Void
    ) {
        self.desktopURL = desktopURL
        self.send = send
    }

    var dragCatcher: DragCatcher? {
        get { lock.withLock { catcher } }
        set { lock.withLock { catcher = newValue } }
    }

    /// Handles a frame if it's part of a transfer. Returns `false` for frames that aren't, such as a program's.
    func handle(_ frame: GuestAgentFrame) -> Bool {
        switch frame.kind {
        case .putFiles:
            startIncoming(on: frame.channel)
        case .transferSize, .fileHeader, .fileData, .filesEnd:
            guard let transfer = lock.withLock({ incoming[frame.channel] }) else { return true }
            transfer.receive(frame)
        case .getFiles:
            startOutgoing(on: frame.channel, paths: frame.pathList)
        case .acknowledge:
            if let bytes = frame.acknowledgedBytes {
                lock.withLock { outgoing[frame.channel] }?.acknowledge(bytes)
            }
        case .catchDrag:
            catchDrag(on: frame.channel)
        case .terminate:
            let (transfer, sender) = lock.withLock { (incoming[frame.channel], outgoing[frame.channel]) }
            guard transfer != nil || sender != nil else { return false }
            transfer?.cancel()
            sender?.cancel()
        default:
            return false
        }
        return true
    }

    func cancelAll() {
        let (transfers, senders) = lock.withLock { (Array(incoming.values), Array(outgoing.values)) }
        transfers.forEach { $0.cancel() }
        senders.forEach { $0.cancel() }
    }

    // MARK: Putting files on the desktop

    private func startIncoming(on channel: UInt32) {
        do {
            let transfer = try IncomingTransfer(channel: channel, destinationURL: try desktopURL(), send: send) { [weak self] in
                guard let self else { return }
                _ = self.lock.withLock { self.incoming.removeValue(forKey: channel) }
            }
            lock.withLock { incoming[channel] = transfer }
        } catch {
            logger.error("Channel \(channel): couldn't receive files: \(error, privacy: .public)")
            send(GuestAgentFrame(.failed, channel: channel, payload: Data("Couldn’t receive the files: \(error.localizedDescription)".utf8)))
        }
    }

    // MARK: Getting files from the guest

    private func startOutgoing(on channel: UInt32, paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }

        let sender: GuestFileSender
        do {
            sender = try GuestFileSender(urls: urls)
        } catch {
            logger.error("Channel \(channel): couldn't read the files to send: \(error, privacy: .public)")
            send(GuestAgentFrame(.failed, channel: channel, payload: Data("Couldn’t read the files: \(error.localizedDescription)".utf8)))
            return
        }

        lock.withLock { outgoing[channel] = sender }

        let thread = Thread { [weak self, send, logger] in
            do {
                try sender.send { kind, payload in send(GuestAgentFrame(kind, channel: channel, payload: payload)) }
            } catch is CancellationError {
                /// The Mac cancelled the transfer, so it isn't told anything more.
            } catch {
                logger.error("Channel \(channel): sending files failed: \(error, privacy: .public)")
                send(GuestAgentFrame(.failed, channel: channel, payload: Data(error.localizedDescription.utf8)))
            }
            guard let self else { return }
            _ = self.lock.withLock { self.outgoing.removeValue(forKey: channel) }
        }
        thread.name = "GuestAgentFileTransfers send"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: Catching drags

    private func catchDrag(on channel: UInt32) {
        guard let catcher = dragCatcher else {
            send(GuestAgentFrame(.failed, channel: channel, payload: Data("This guest can’t catch drags.".utf8)))
            return
        }

        Task { @MainActor [send] in
            let items = await catcher()
            send(GuestAgentFrame(.dragItems, channel: channel, payload: GuestDragItem.payload(for: items)))
        }
    }
}

/// Files that the Mac puts on the guest's desktop. They're written into a hidden folder there first, so that nothing is seen
/// half written, then moved into place once they've all arrived.
private final class IncomingTransfer: @unchecked Sendable {
    private let channel: UInt32
    private let destinationURL: URL
    private let stagingURL: URL
    private let receiver: GuestFileReceiver
    private let send: @Sendable (GuestAgentFrame) -> Void
    private let onEnd: @Sendable () -> Void
    private let queue: DispatchQueue
    private var hasEnded = false

    init(channel: UInt32, destinationURL: URL, send: @escaping @Sendable (GuestAgentFrame) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        self.channel = channel
        self.destinationURL = destinationURL
        self.send = send
        self.onEnd = onEnd
        self.queue = DispatchQueue(label: "IncomingTransfer.\(channel)", qos: .userInitiated)

        stagingURL = destinationURL.appending(path: ".hypervisaur-\(channel)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        receiver = GuestFileReceiver(rootURL: stagingURL)
    }

    /// Frames are written in order on the transfer's queue, so that writing doesn't hold up the guest app.
    func receive(_ frame: GuestAgentFrame) {
        queue.async { [self] in
            guard !hasEnded else { return }
            do {
                if let acknowledgement = try receiver.receive(frame) {
                    send(GuestAgentFrame(.acknowledge, channel: channel, payload: GuestAgentFrame.acknowledgement(acknowledgement)))
                }
                if receiver.isComplete {
                    let paths = try moveIntoPlace()
                    end()
                    send(GuestAgentFrame(.transferred, channel: channel, payload: GuestAgentFrame.pathList(paths)))
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !hasEnded else { return }
            fail("Cancelled.")
        }
    }

    private func moveIntoPlace() throws -> [String] {
        var paths = [String]()
        for url in receiver.topLevelURLs {
            let destination = uniqueURL(forItemNamed: url.lastPathComponent, in: destinationURL)
            try FileManager.default.moveItem(at: url, to: destination)
            paths.append(destination.path(percentEncoded: false))
        }
        return paths
    }

    private func fail(_ message: String) {
        receiver.abandon()
        end()
        send(GuestAgentFrame(.failed, channel: channel, payload: Data(message.utf8)))
    }

    private func end() {
        hasEnded = true
        try? FileManager.default.removeItem(at: stagingURL)
        onEnd()
    }
}
