import Foundation
import Virtualization

/// The virtio console port that the Hypervisaur agent in a Linux guest uses, at `/dev/virtio-ports/hypervisaur.agent`.
///
/// Virtualization connects the port to one end of a socket pair, and the agent's frames are read from and written to the other.
@available(macOS 13.0, *)
final class GuestAgentConsolePort {
    static let name = "hypervisaur.agent"

    let configuration: VZVirtioConsolePortConfiguration
    let socket: UnixSocketConnection

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError.current
        }

        let guestEnd = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)

        configuration = VZVirtioConsolePortConfiguration()
        configuration.name = Self.name
        configuration.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: guestEnd, fileHandleForWriting: guestEnd)

        socket = UnixSocketConnection(fileDescriptor: descriptors[0])
    }
}
