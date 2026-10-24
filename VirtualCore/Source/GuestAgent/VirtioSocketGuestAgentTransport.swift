import Foundation
import VirtualWormhole

/// Carries the frames of the agent in a Linux or macOS guest over a virtio socket when the agent listens on one, and over
/// its other link until then: its console port in Linux guests, and the guest app's messages in macOS guests.
///
/// Those other links are far too slow for copying files: Virtualization connects console ports through a serial port
/// attachment, and the guest app's messages are encoded as JSON. Agents that come with Hypervisaur 0.3 or later also listen
/// on ``GuestAgentFrame/socketPort``, so the Mac moves to the socket once it can connect to it, and back to the other link
/// if the socket closes, such as while the agent restarts. Older agents only use the other link.
final class VirtioSocketGuestAgentTransport: GuestAgentTransport, @unchecked Sendable {
    private let fallback: GuestAgentTransport
    private let lock = NSLock()
    private var socketTransport: GuestAgentStreamTransport?
    private var onFrame: (@Sendable (GuestAgentFrame) -> Void)?

    init(fallback: GuestAgentTransport) {
        self.fallback = fallback
    }

    var isUsingSocket: Bool { lock.withLock { socketTransport != nil } }

    func start(onFrame: @escaping @Sendable (GuestAgentFrame) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { self.onFrame = onFrame }

        /// The agent keeps its other link open while it uses the socket, but only one of them is listened to at a time.
        fallback.start { [weak self] frame in
            guard let self, !self.isUsingSocket else { return }
            onFrame(frame)
        } onClose: { error in
            onClose(error)
        }
    }

    func send(_ frame: GuestAgentFrame) throws {
        if let socketTransport = lock.withLock({ socketTransport }) {
            try socketTransport.send(frame)
        } else {
            try fallback.send(frame)
        }
    }

    func close() {
        let socketTransport = lock.withLock {
            defer { self.socketTransport = nil }
            return self.socketTransport
        }
        socketTransport?.close()
        fallback.close()
    }

    /// Sends and receives frames over the socket from now on. `onDisconnect` is called when the socket closes, after which
    /// frames go over the other link again.
    func use(_ socket: UnixSocketConnection, onDisconnect: @escaping @Sendable () -> Void) {
        let transport = GuestAgentStreamTransport(name: "GuestAgent socket", socket: socket)
        let previous = lock.withLock {
            defer { socketTransport = transport }
            return socketTransport
        }
        previous?.close()

        transport.start { [weak self] frame in
            guard let self, self.lock.withLock({ self.socketTransport === transport }) else { return }
            self.lock.withLock { self.onFrame }?(frame)
        } onClose: { [weak self] _ in
            guard let self else { return }
            let wasCurrent = self.lock.withLock {
                guard self.socketTransport === transport else { return false }
                self.socketTransport = nil
                return true
            }
            if wasCurrent {
                onDisconnect()
            }
        }
    }
}
