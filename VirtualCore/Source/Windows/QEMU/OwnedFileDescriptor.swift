import Foundation
import Darwin

/// A file descriptor that's closed when nothing refers to it any more, such as one that's passed to or from another process.
final class OwnedFileDescriptor: @unchecked Sendable {
    let rawValue: Int32

    /// Takes over the descriptor, which this closes.
    init(taking rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Makes a pair of connected Unix domain sockets, which aren't inherited by programs that Hypervisaur starts.
    static func socketPair() throws -> (OwnedFileDescriptor, OwnedFileDescriptor) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError.current }

        let pair = (OwnedFileDescriptor(taking: descriptors[0]), OwnedFileDescriptor(taking: descriptors[1]))
        pair.0.closeOnExec()
        pair.1.closeOnExec()
        return pair
    }

    /// Stops programs that Hypervisaur starts from inheriting the descriptor.
    func closeOnExec() {
        _ = fcntl(rawValue, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        Darwin.close(rawValue)
    }
}
