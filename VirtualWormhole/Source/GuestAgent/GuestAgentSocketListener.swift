import Foundation
import Darwin
import OSLog

/// Serves the Hypervisaur agent in a macOS guest on a virtio socket, which the Mac connects to and prefers over the guest
/// app's messages, since frames on it aren't encoded as messages and it's many times faster for copying files.
///
/// It serves one connection at a time, with an agent of its own, while the agent that the guest app's messages reach keeps
/// running, so that either can be used.
final class GuestAgentSocketListener: @unchecked Sendable {
    private let port: UInt32
    private let logger = Logger(subsystem: VirtualWormholeConstants.subsystemName, category: "GuestAgentSocketListener")
    private let lock = NSLock()
    private var connection: Int32 = -1
    private var runner: GuestAgentRunner?
    private var isStopped = true
    private var catcher: GuestAgentFileTransfers.DragCatcher?

    init(port: UInt32 = GuestAgentFrame.socketPort) {
        self.port = port
    }

    var dragCatcher: GuestAgentFileTransfers.DragCatcher? {
        get { lock.withLock { catcher } }
        set {
            let runner = lock.withLock {
                catcher = newValue
                return self.runner
            }
            runner?.dragCatcher = newValue
        }
    }

    func start() {
        let shouldStart = lock.withLock {
            defer { isStopped = false }
            return isStopped
        }
        guard shouldStart else { return }

        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "GuestAgentSocketListener"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The thread that serves the socket notices within a second, and closes the sockets itself.
    func stop() {
        let connection = lock.withLock {
            isStopped = true
            return self.connection
        }
        /// Shutting the connection down ends the read that's waiting on it.
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
    }

    private var shouldStop: Bool { lock.withLock { isStopped } }

    private func serve() {
        while !shouldStop {
            let listener = makeListener()
            guard listener >= 0 else {
                Thread.sleep(forTimeInterval: 10)
                continue
            }
            logger.notice("Listening on virtio socket port \(self.port)")

            while !shouldStop {
                /// Waiting a second at a time lets the thread notice when it's stopped.
                var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, 1000)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { break }

                let connection = accept(listener, nil, nil)
                guard connection >= 0 else {
                    if errno == EINTR { continue }
                    if !shouldStop {
                        logger.error("The virtio socket stopped accepting connections: \(String(cString: strerror(errno)), privacy: .public)")
                    }
                    break
                }
                serve(connection)
            }

            close(listener)
        }
    }

    private func makeListener() -> Int32 {
        let descriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            logger.error("Couldn't make a virtio socket: \(String(cString: strerror(errno)), privacy: .public)")
            return -1
        }

        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = port
        address.svm_cid = UInt32(VMADDR_CID_ANY)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            logger.error("Couldn't listen on virtio socket port \(self.port): \(String(cString: strerror(errno)), privacy: .public)")
            close(descriptor)
            return -1
        }
        return descriptor
    }

    /// Runs an agent for the connection until it closes.
    private func serve(_ connection: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let writeLock = NSLock()
        let runner = GuestAgentRunner { data in
            writeLock.withLock { Self.writeAll(data, to: connection) }
        }
        runner.dragCatcher = dragCatcher
        lock.withLock {
            self.connection = connection
            self.runner = runner
        }
        logger.notice("The Mac connected over the virtio socket")

        runner.connected()

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = read(connection, &buffer, buffer.count)
            if count > 0 {
                runner.receive(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }

        runner.disconnected()
        lock.withLock {
            if self.connection == connection { self.connection = -1 }
            self.runner = nil
        }
        close(connection)
        logger.notice("The Mac disconnected from the virtio socket")
    }

    /// Frames are dropped if the Mac has gone, since nobody is listening for them then.
    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
