import Foundation
import VirtualWormhole
import OSLog

/// Copies files to or from a guest through its Hypervisaur agent.
///
/// Progress is reported as the receiving side writes the data, which is what the acknowledgements say, so it shows how much
/// has really arrived.
public final class GuestFileTransferOperation: @unchecked Sendable {
    public enum Direction: Sendable {
        /// Files and folders on the Mac are put on the guest's desktop.
        case toGuest([URL])
        /// A file or folder in the guest is copied to a URL on the Mac.
        case fromGuest(path: String, destination: URL)
    }

    public struct Progress: Sendable {
        public var completedBytes: UInt64
        /// `nil` until the sender says how large the transfer is.
        public var totalBytes: UInt64?
    }

    public let direction: Direction

    private let connection: GuestAgentConnection
    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "GuestFileTransfer")
    private let lock = NSLock()
    private var channel: GuestAgentConnection.TransferChannel?
    private var sender: GuestFileSender?
    private var isCancelled = false

    public init(_ direction: Direction, connection: GuestAgentConnection) {
        self.direction = direction
        self.connection = connection
    }

    /// Runs the transfer. Returns the paths in the guest that files were put at, or the URL on the Mac that the file or
    /// folder was copied to. Throws `CancellationError` if it's cancelled.
    @discardableResult
    public func run(progress: @escaping @Sendable (Progress) -> Void) async throws -> [String] {
        switch direction {
        case .toGuest(let urls):
            return try await put(urls, progress: progress)
        case .fromGuest(let path, let destination):
            try await get(path, to: destination, progress: progress)
            return [destination.path(percentEncoded: false)]
        }
    }

    public func cancel() {
        let (channel, sender) = lock.withLock { () -> (GuestAgentConnection.TransferChannel?, GuestFileSender?) in
            isCancelled = true
            return (self.channel, self.sender)
        }
        sender?.cancel()
        channel?.cancel()
    }

    // MARK: To the guest

    private func put(_ urls: [URL], progress: @escaping @Sendable (Progress) -> Void) async throws -> [String] {
        /// Folders can hold a great many files, so they're found away from the caller's thread.
        let sender = try await Task.detached(priority: .userInitiated) { try GuestFileSender(urls: urls) }.value
        let totalBytes = sender.size.totalBytes

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                let completion = OnceContinuation(continuation)

                let channel: GuestAgentConnection.TransferChannel
                do {
                    channel = try connection.openTransfer(.putFiles, payload: Data([GuestFileDestination.desktop.rawValue])) { event in
                        switch event {
                        case .frame(let frame):
                            guard let bytes = frame.acknowledgedBytes else { return }
                            sender.acknowledge(bytes)
                            progress(Progress(completedBytes: bytes, totalBytes: totalBytes))
                        case .transferred(let paths):
                            completion.resume(returning: paths)
                        case .failed(let message):
                            sender.cancel()
                            completion.resume(throwing: self.isCancelledNow ? CancellationError() : Failure(message))
                        case .filesEnd, .dragItems:
                            sender.cancel()
                            completion.resume(throwing: Failure("The guest agent replied to the transfer unexpectedly."))
                        }
                    }
                } catch {
                    completion.resume(throwing: error)
                    return
                }

                let wasCancelled = lock.withLock {
                    self.channel = channel
                    self.sender = sender
                    return isCancelled
                }
                if wasCancelled {
                    cancel()
                }

                progress(Progress(completedBytes: 0, totalBytes: totalBytes))

                let thread = Thread { [logger] in
                    do {
                        try sender.send { kind, payload in try channel.send(kind, payload) }
                    } catch is CancellationError {
                        /// The agent replies to the cancellation, which ends the transfer.
                    } catch {
                        logger.error("Sending files failed: \(error, privacy: .public)")
                        channel.cancel()
                        self.connection.forget(channel)
                        completion.resume(throwing: error)
                    }
                }
                thread.name = "GuestFileTransfer send"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancel()
        }
    }

    // MARK: From the guest

    private func get(_ path: String, to destination: URL, progress: @escaping @Sendable (Progress) -> Void) async throws {
        let folderURL = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let receiver = GuestFileReceiver(rootURL: folderURL, topLevelName: { _ in name })

        /// Frames arrive on the transport's thread one at a time, so the receiver is only used from there.
        let receiverLock = NSLock()

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion = OnceContinuation(continuation)
                    var channel: GuestAgentConnection.TransferChannel?

                    do {
                        channel = try connection.openTransfer(.getFiles, payload: GuestAgentFrame.pathList([path])) { [weak self] event in
                            guard let self else { return }

                            func fail(_ error: Error) {
                                if let channel = self.lock.withLock({ self.channel }) {
                                    channel.cancel()
                                    self.connection.forget(channel)
                                }
                                completion.resume(throwing: error)
                            }

                            do {
                                switch event {
                                case .frame(let frame):
                                    let acknowledgement = try receiverLock.withLock { try receiver.receive(frame) }
                                    if let acknowledgement, let channel = self.lock.withLock({ self.channel }) {
                                        try channel.send(.acknowledge, GuestAgentFrame.acknowledgement(acknowledgement))
                                    }
                                    let (written, total) = receiverLock.withLock { (receiver.writtenBytes, receiver.size?.totalBytes) }
                                    progress(Progress(completedBytes: written, totalBytes: total))
                                case .filesEnd:
                                    _ = try receiverLock.withLock { try receiver.receive(GuestAgentFrame(.filesEnd, channel: 0)) }
                                    completion.resume(returning: ())
                                case .failed(let message):
                                    completion.resume(throwing: self.isCancelledNow ? CancellationError() : Failure(message))
                                case .transferred, .dragItems:
                                    fail(Failure("The guest agent replied to the transfer unexpectedly."))
                                }
                            } catch {
                                fail(error)
                            }
                        }
                    } catch {
                        completion.resume(throwing: error)
                        return
                    }

                    let wasCancelled = lock.withLock {
                        self.channel = channel
                        return isCancelled
                    }
                    if wasCancelled, let channel {
                        /// The agent stops without replying, so the transfer ends here.
                        channel.cancel()
                        connection.forget(channel)
                        completion.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                cancelGet()
            }
        } catch {
            receiverLock.withLock { receiver.abandon() }
            for url in receiverLock.withLock({ receiver.topLevelURLs }) {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// The agent stops sending without replying, so a cancelled transfer from the guest ends on the Mac's side.
    private func cancelGet() {
        cancel()
        if let channel = lock.withLock({ channel }) {
            connection.forget(channel)
        }
    }

    private var isCancelledNow: Bool { lock.withLock { isCancelled } }
}

public extension GuestFileTransferOperation {
    /// Asks the agent which files are being dragged in the guest. It catches the drag with a window under the guest's
    /// pointer, which the drag has to move over, so `nudge` is called until the agent replies, to move the guest's pointer a little.
    static func catchDrag(over connection: GuestAgentConnection, timeout: Duration = .seconds(5), nudge: @escaping @MainActor () -> Void) async throws -> [GuestDragItem] {
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[GuestDragItem], Error>) in
            let completion = OnceContinuation(continuation)

            do {
                let channel = try connection.openTransfer(.catchDrag) { event in
                    switch event {
                    case .dragItems(let items): completion.resume(returning: items)
                    case .failed(let message): completion.resume(throwing: Failure(message))
                    case .frame, .filesEnd, .transferred: completion.resume(throwing: Failure("The guest agent replied to the drag unexpectedly."))
                    }
                }

                Task { @MainActor in
                    let clock = ContinuousClock()
                    let deadline = clock.now + timeout
                    while !completion.isResumed, clock.now < deadline {
                        nudge()
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if !completion.isResumed {
                        connection.forget(channel)
                        completion.resume(returning: [])
                    }
                }
            } catch {
                completion.resume(throwing: error)
            }
        }
        return result
    }
}

/// Resumes a continuation once, however many times it's asked to, since a transfer can end in more than one way at once.
private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    var isResumed: Bool { lock.withLock { continuation == nil } }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
