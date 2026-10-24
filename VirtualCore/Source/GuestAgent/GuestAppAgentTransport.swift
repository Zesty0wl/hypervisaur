import Foundation
import VirtualWormhole

/// Carries the agent's frames with the guest app's other messages, for macOS guests, whose agent is part of the guest app.
final class GuestAppAgentTransport: GuestAgentTransport, @unchecked Sendable {
    private let lock = NSLock()
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
        let (frames, onFrame) = lock.withLock { () -> ([GuestAgentFrame], (@Sendable (GuestAgentFrame) -> Void)?) in
            do {
                return (try decoder.decode(data), self.onFrame)
            } catch {
                decoder = GuestAgentFrameDecoder()
                return ([], self.onFrame)
            }
        }
        for frame in frames {
            onFrame?(frame)
        }
    }
}
