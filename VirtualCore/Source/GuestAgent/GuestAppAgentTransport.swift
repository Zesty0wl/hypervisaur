import Foundation
import VirtualWormhole

/// Carries the agent's frames with the guest app's other messages, for macOS guests, whose agent is part of the guest app.
final class GuestAppAgentTransport: GuestAgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    /// Frames from the guest are decoded on a queue of their own rather than the main actor that delivers them, since the
    /// guest decides how many arrive at once. The queue is serial, which keeps them in order.
    private let receiveQueue = DispatchQueue(label: "GuestAppAgentTransport.receive")
    private var decoder = GuestAgentFrameDecoder()
    private var onFrame: (@Sendable (GuestAgentFrame) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    private weak var session: HostGuestSession?

    @MainActor
    init(session: HostGuestSession) {
        self.session = session

        session.onAgentFrames = { [weak self] data in
            self?.receive(data)
        }
    }

    func start(onFrame: @escaping @Sendable (GuestAgentFrame) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            self.onFrame = onFrame
            self.onClose = onClose
        }
    }

    /// Frames are passed to the session through the main queue, which keeps them in order.
    func send(_ frame: GuestAgentFrame) throws {
        let data = frame.encoded()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.session?.sendAgentFrames(data) }
        }
    }

    func close() {
        let onClose = lock.withLock {
            defer { self.onClose = nil; self.onFrame = nil }
            return self.onClose
        }
        onClose?(nil)
    }

    private func receive(_ data: Data) {
        receiveQueue.async { [weak self] in
            guard let self else { return }
            let (frames, onFrame) = lock.withLock { () -> ([GuestAgentFrame], (@Sendable (GuestAgentFrame) -> Void)?) in
                do {
                    return (try self.decoder.decode(data), self.onFrame)
                } catch {
                    self.decoder = GuestAgentFrameDecoder()
                    return ([], self.onFrame)
                }
            }
            for frame in frames {
                onFrame?(frame)
            }
        }
    }
}
