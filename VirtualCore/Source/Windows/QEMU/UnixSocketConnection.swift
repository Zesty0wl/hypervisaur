import Foundation
import Darwin

/// A blocking connection to a Unix domain socket.
///
/// Reads are expected to happen on a single dedicated thread, writes may happen from any thread.
final class UnixSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var isClosed = false

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw Failure("Socket path is too long: \(path)")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            let error = POSIXError.current
            Darwin.close(fd)
            throw error
        }

        self.fd = fd
    }

    /// Takes over a connected socket, such as one that a listening socket accepted.
    init(fileDescriptor fd: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        self.fd = fd
    }

    /// Connects to the socket at the path, retrying until it's available or the deadline passes.
    static func connect(path: String, timeout: Duration, isCancelled: () -> Bool = { false }) async throws -> UnixSocketConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            do {
                return try UnixSocketConnection(path: path)
            } catch {
                guard clock.now < deadline, !isCancelled() else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Reads exactly `count` bytes. Throws if the connection is closed before that.
    func read(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            try read(into: buffer)
        }
        return data
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }

        var offset = 0
        while offset < buffer.count {
            let result = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
            if result > 0 {
                offset += result
            } else if result == 0 {
                throw Failure("The connection was closed.")
            } else if errno != EINTR {
                throw POSIXError.current
            }
        }
    }

    /// Reads whatever is available, up to `maxLength` bytes, waiting until something is. Returns `nil` once the connection is closed.
    func readAvailable(maxLength: Int) throws -> Data? {
        var data = Data(count: maxLength)
        while true {
            let result = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxLength) }
            if result > 0 {
                return data.prefix(result)
            } else if result == 0 {
                return nil
            } else if errno != EINTR {
                throw POSIXError.current
            }
        }
    }

    func readByte() throws -> UInt8 {
        var byte: UInt8 = 0
        try withUnsafeMutableBytes(of: &byte) { try read(into: $0) }
        return byte
    }

    /// - Parameter descriptor: A file descriptor that's passed to the peer along with the data, such as for QEMU's `getfd` command.
    func write(_ data: Data, passing descriptor: OwnedFileDescriptor? = nil) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }

            var offset = 0
            if let descriptor {
                offset = try SocketControlMessage.send(buffer, passing: [descriptor.rawValue], on: fd)
            }

            while offset < buffer.count {
                let result = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if result >= 0 {
                    offset += result
                } else if errno != EINTR {
                    throw POSIXError.current
                }
            }
        }
    }

    /// Wakes up any blocked reads. The descriptor itself is only released on deinit, so that it can't be reused while a read is in flight.
    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }

        guard !isClosed else { return }
        isClosed = true

        shutdown(fd, SHUT_RDWR)
    }

    deinit {
        close()
        Darwin.close(fd)
    }
}

extension POSIXError {
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
