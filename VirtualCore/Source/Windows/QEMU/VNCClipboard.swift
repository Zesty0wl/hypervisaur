import Foundation
import BuddyFoundation

/// The RFB extended clipboard extension, which is how QEMU's VNC server shares the clipboard with clients.
/// QEMU passes the clipboard to and from the guest through the SPICE agent that's installed in it.
///
/// Only text is shared. A side announces that it has text with a notification, the other side requests it when it's
/// needed, and it's provided compressed with zlib, as UTF-8 with Windows line endings and a terminating null character.
enum VNCClipboard {
    static let encoding = Int32(bitPattern: 0xC0A1_E5CE)

    struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: UInt32

        static let text = Flags(rawValue: 1 << 0)
        static let capabilities = Flags(rawValue: 1 << 24)
        static let request = Flags(rawValue: 1 << 25)
        static let notify = Flags(rawValue: 1 << 27)
        static let provide = Flags(rawValue: 1 << 28)
    }

    /// QEMU won't decompress more than a megabyte, which is far more text than anyone copies.
    static let maximumTextSize = 1024 * 1024 - 8

    /// The most that's read from the server in one message, which is generous for a megabyte of compressed text.
    static let maximumMessageSize = 2 * 1024 * 1024

    /// A client cut text message with the extension's flags, and the data that goes with them.
    static func clientMessage(_ flags: Flags, payload: Data = Data()) -> Data {
        var message = Data([6, 0, 0, 0])
        message.appendBigEndian(Int32(-(4 + payload.count)))
        message.appendBigEndian(flags.rawValue)
        message.append(payload)
        return message
    }

    /// Says which messages and formats the client supports, with the largest text it accepts.
    static var capabilitiesMessage: Data {
        var payload = Data()
        payload.appendBigEndian(UInt32(maximumTextSize))
        return clientMessage([.capabilities, .request, .notify, .provide, .text], payload: payload)
    }

    /// The compressed text for a provide message, or `nil` if it's too much to send.
    static func providePayload(for text: String) throws -> Data? {
        var bytes = Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
        bytes.append(0)

        guard bytes.count <= maximumTextSize else { return nil }

        var contents = Data()
        contents.appendBigEndian(UInt32(bytes.count))
        contents.append(bytes)

        return try ZlibStream.compress(contents)
    }

    /// The text in a provide message from the server.
    static func text(fromProvidePayload payload: Data) throws -> String {
        let contents = try ZlibStream.decompress(payload, maximumSize: maximumTextSize + 4)

        guard contents.count >= 4 else { throw Failure("The clipboard data is incomplete.") }

        let size = Int(contents.bigEndianUInt32(at: 0))
        guard size <= contents.count - 4 else { throw Failure("The clipboard data is incomplete.") }

        var bytes = contents.subdata(in: (contents.startIndex + 4)..<(contents.startIndex + 4 + size))
        while bytes.last == 0 {
            bytes.removeLast()
        }

        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }
}

/// Data compressed in the zlib format, which is DEFLATE data with a header and a checksum.
enum ZlibStream {
    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data

        /// Deflate with a 32K window and the default compression level, without a preset dictionary.
        var stream = Data([0x78, 0x9C])
        stream.append(deflated)
        stream.appendBigEndian(adler32(data))
        return stream
    }

    static func decompress(_ stream: Data, maximumSize: Int) throws -> Data {
        guard stream.count >= 6 else { throw Failure("The compressed data is incomplete.") }

        let method = stream[stream.startIndex]
        let flags = stream[stream.startIndex + 1]
        guard method & 0x0F == 8, (UInt16(method) << 8 | UInt16(flags)) % 31 == 0, flags & 0x20 == 0 else {
            throw Failure("The data isn’t compressed with zlib.")
        }

        let deflated = stream.subdata(in: (stream.startIndex + 2)..<(stream.endIndex - 4))
        let data = try (deflated as NSData).decompressed(using: .zlib) as Data

        guard data.count <= maximumSize else { throw Failure("The compressed data is too large.") }
        guard adler32(data) == stream.bigEndianUInt32(at: stream.count - 4) else {
            throw Failure("The compressed data is damaged.")
        }

        return data
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0

        /// The sums are reduced every 5552 bytes, the most that can be added up without overflowing.
        data.withUnsafeBytes { buffer in
            var index = buffer.startIndex
            while index < buffer.endIndex {
                let end = min(index + 5552, buffer.endIndex)
                for byte in buffer[index..<end] {
                    a += UInt32(byte)
                    b += a
                }
                a %= 65521
                b %= 65521
                index = end
            }
        }

        return b << 16 | a
    }
}
