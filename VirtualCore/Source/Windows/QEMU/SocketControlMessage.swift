import Foundation
import Darwin

/// Passes file descriptors over Unix domain sockets, with control messages laid out as the `CMSG` macros in
/// `<sys/socket.h>` lay them out, since the macros aren't available in Swift.
enum SocketControlMessage {
    /// The size of `struct cmsghdr`: its length, level and type.
    private static let headerLength = 12

    private static func aligned(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    /// The space that control messages need for passing this many descriptors.
    static func space(forDescriptors count: Int) -> Int {
        aligned(headerLength) + aligned(count * MemoryLayout<Int32>.size)
    }

    /// Sends the start of the data along with the descriptors.
    /// - Returns: How many bytes were sent, which the rest of the data has to be sent after.
    static func send(_ data: UnsafeRawBufferPointer, passing descriptors: [Int32], on socket: Int32) throws -> Int {
        var control = rights(descriptors)

        while true {
            let result = control.withUnsafeMutableBytes { controlBuffer in
                var vector = iovec(iov_base: UnsafeMutableRawPointer(mutating: data.baseAddress), iov_len: data.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var header = msghdr()
                    header.msg_iov = vectorPointer
                    header.msg_iovlen = 1
                    header.msg_control = controlBuffer.baseAddress
                    header.msg_controllen = socklen_t(controlBuffer.count)
                    return sendmsg(socket, &header, 0)
                }
            }

            if result >= 0 {
                return result
            } else if errno != EINTR {
                throw POSIXError.current
            }
        }
    }

    /// Reads whatever is available, with the descriptors that came with it, which programs Hypervisaur starts don't inherit.
    ///
    /// - Returns: How many bytes were read, which is 0 once the peer has closed the connection.
    static func receive(into data: UnsafeMutableRawBufferPointer, descriptors: inout [OwnedFileDescriptor], maximumDescriptors: Int, on socket: Int32) throws -> Int {
        var control = [UInt8](repeating: 0, count: space(forDescriptors: maximumDescriptors))

        while true {
            let (count, flags, received): (Int, Int32, [Int32]) = control.withUnsafeMutableBytes { controlBuffer in
                var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var header = msghdr()
                    header.msg_iov = vectorPointer
                    header.msg_iovlen = 1
                    header.msg_control = controlBuffer.baseAddress
                    header.msg_controllen = socklen_t(controlBuffer.count)

                    let count = recvmsg(socket, &header, 0)
                    let controlLength = count >= 0 ? min(Int(header.msg_controllen), controlBuffer.count) : 0
                    return (count, header.msg_flags, passedDescriptors(in: UnsafeRawBufferPointer(rebasing: controlBuffer[..<controlLength])))
                }
            }

            let receivedDescriptors = received.map(OwnedFileDescriptor.init(taking:))
            receivedDescriptors.forEach { $0.closeOnExec() }

            if count >= 0 {
                guard flags & MSG_CTRUNC == 0 else {
                    throw Failure("More file descriptors came at once than are accepted.")
                }
                descriptors.append(contentsOf: receivedDescriptors)
                return count
            } else if errno != EINTR {
                throw POSIXError.current
            }
        }
    }

    private static func rights(_ descriptors: [Int32]) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: space(forDescriptors: descriptors.count))
        message.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(of: UInt32(aligned(headerLength) + descriptors.count * MemoryLayout<Int32>.size), toByteOffset: 0, as: UInt32.self)
            buffer.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
            buffer.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self)
            for (index, descriptor) in descriptors.enumerated() {
                buffer.storeBytes(of: descriptor, toByteOffset: aligned(headerLength) + index * MemoryLayout<Int32>.size, as: Int32.self)
            }
        }
        return message
    }

    private static func passedDescriptors(in buffer: UnsafeRawBufferPointer) -> [Int32] {
        var descriptors = [Int32]()
        var offset = 0

        while offset + headerLength <= buffer.count {
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length >= headerLength, offset + length <= buffer.count else { break }

            let level = buffer.loadUnaligned(fromByteOffset: offset + 4, as: Int32.self)
            let type = buffer.loadUnaligned(fromByteOffset: offset + 8, as: Int32.self)

            if level == SOL_SOCKET, type == SCM_RIGHTS {
                let dataOffset = offset + aligned(headerLength)
                let count = (length - aligned(headerLength)) / MemoryLayout<Int32>.size
                for index in 0..<count {
                    descriptors.append(buffer.loadUnaligned(fromByteOffset: dataOffset + index * MemoryLayout<Int32>.size, as: Int32.self))
                }
            }

            offset += aligned(length)
        }

        return descriptors
    }
}
