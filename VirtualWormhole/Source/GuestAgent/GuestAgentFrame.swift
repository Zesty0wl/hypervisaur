import Foundation

/// A message to or from the Hypervisaur agent in a guest, which runs programs there for the Mac.
///
/// The agent runs each program on its own channel, so several can run at once over one connection. Programs on the Mac that
/// use the agent through Hypervisaur, such as `hvctl` and `vbmcp`, exchange the same frames with it on a single channel.
///
/// A frame is a header of the payload's length (`UInt32`), its kind (`UInt8`) and its channel (`UInt32`), all little-endian,
/// followed by the payload.
public struct GuestAgentFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// Sent to the agent when the Mac connects, on channel 0. The agent stops anything still running from an earlier
        /// connection and replies with ``hello``.
        case reset = 0x01
        /// Starts a program on a new channel. See ``GuestAgentOpenRequest``.
        case open = 0x02
        /// Input for the program.
        case input = 0x03
        /// Closes the program's input.
        case inputEnd = 0x04
        /// Changes the size of the program's terminal, as two `UInt16`s: columns then rows.
        case resize = 0x05
        /// Stops the program.
        case terminate = 0x06

        /// Sent by the agent on channel 0 when it starts and after ``reset``. See ``GuestAgentInfo``.
        case hello = 0x41
        /// Output from the program, which includes its errors when it runs in a terminal.
        case output = 0x42
        /// Error output from the program.
        case errorOutput = 0x43
        /// The program has exited, with its exit status as an `Int32`. Nothing else is sent on the channel afterwards.
        case exited = 0x44
        /// The program couldn't be started, or stopped for a reason other than exiting, with a UTF-8 description.
        case failed = 0x45
    }

    public var kind: Kind
    public var channel: UInt32
    public var payload: Data

    public init(_ kind: Kind, channel: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.channel = channel
        self.payload = payload
    }

    static let headerSize = 9

    /// Larger payloads are a sign that the other side doesn't speak this protocol, so the connection is dropped.
    public static let maximumPayloadSize = 1 << 20

    /// Output is sent in pieces no larger than this, so that one program can't hold up the others for long.
    public static let preferredChunkSize = 16 * 1024

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.appendLittleEndian(UInt32(payload.count))
        data.append(kind.rawValue)
        data.appendLittleEndian(channel)
        data.append(payload)
        return data
    }
}

/// Splits a stream of bytes into frames.
public struct GuestAgentFrameDecoder: Sendable {
    private var buffer = Data()

    public init() { }

    /// Adds bytes that were received and returns the frames that are now complete. Frames of kinds that aren't known are
    /// skipped, so that newer agents can add them.
    public mutating func decode(_ data: Data) throws -> [GuestAgentFrame] {
        buffer.append(data)

        var frames = [GuestAgentFrame]()
        while buffer.count >= GuestAgentFrame.headerSize {
            let start = buffer.startIndex
            let length = Int(buffer.littleEndianUInt32(at: start))

            guard length <= GuestAgentFrame.maximumPayloadSize else {
                throw GuestAgentError("The guest agent sent a message that's too large (\(length) bytes).")
            }

            let frameSize = GuestAgentFrame.headerSize + length
            guard buffer.count >= frameSize else { break }

            let kindValue = buffer[start + 4]
            let channel = buffer.littleEndianUInt32(at: start + 5)
            let payload = Data(buffer[(start + GuestAgentFrame.headerSize)..<(start + frameSize)])
            buffer.removeSubrange(start..<(start + frameSize))

            if let kind = GuestAgentFrame.Kind(rawValue: kindValue) {
                frames.append(GuestAgentFrame(kind, channel: channel, payload: payload))
            }
        }
        return frames
    }
}

/// Asks the agent to start a program.
public struct GuestAgentOpenRequest: Equatable, Sendable {
    /// What to run, which the agent runs with the guest's shell: PowerShell on Windows, `/bin/sh` on Linux, and the user's
    /// login shell on macOS.
    /// An empty command starts an interactive shell.
    public var command: String
    /// Whether the program runs in a terminal of its own, which interactive programs need.
    public var usesTerminal: Bool
    public var columns: UInt16
    public var rows: UInt16

    public init(command: String, usesTerminal: Bool = false, columns: UInt16 = 80, rows: UInt16 = 24) {
        self.command = command
        self.usesTerminal = usesTerminal
        self.columns = columns
        self.rows = rows
    }

    /// The payload is a byte of flags, where the first bit means ``usesTerminal``, the terminal's columns and rows as `UInt16`s,
    /// and then the command in UTF-8.
    public var payload: Data {
        var data = Data()
        data.append(usesTerminal ? 1 : 0)
        data.appendLittleEndian(columns)
        data.appendLittleEndian(rows)
        data.append(Data(command.utf8))
        return data
    }

    public init(payload: Data) throws {
        guard payload.count >= 5 else { throw GuestAgentError("The request to run a program is incomplete.") }

        let start = payload.startIndex
        usesTerminal = payload[start] & 1 != 0
        columns = payload.littleEndianUInt16(at: start + 1)
        rows = payload.littleEndianUInt16(at: start + 3)
        command = String(decoding: payload[(start + 5)...], as: UTF8.self)
    }
}

/// What the agent says about itself when it connects.
public struct GuestAgentInfo: Equatable, Sendable {
    public var protocolVersion: UInt32
    /// A description of the guest's operating system, such as "Windows 11 Pro 10.0.26300 ARM64".
    public var system: String

    public init(protocolVersion: UInt32, system: String) {
        self.protocolVersion = protocolVersion
        self.system = system
    }

    public var payload: Data {
        var data = Data()
        data.appendLittleEndian(protocolVersion)
        data.append(Data(system.utf8))
        return data
    }

    public init(payload: Data) throws {
        guard payload.count >= 4 else { throw GuestAgentError("The guest agent's greeting is incomplete.") }
        protocolVersion = payload.littleEndianUInt32(at: payload.startIndex)
        system = String(decoding: payload.dropFirst(4), as: UTF8.self)
    }
}

public extension GuestAgentFrame {
    static func exitStatus(_ status: Int32) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(bitPattern: status))
        return data
    }

    static func terminalSize(columns: UInt16, rows: UInt16) -> Data {
        var data = Data()
        data.appendLittleEndian(columns)
        data.appendLittleEndian(rows)
        return data
    }

    var exitStatus: Int32? {
        guard kind == .exited, payload.count >= 4 else { return nil }
        return Int32(bitPattern: payload.littleEndianUInt32(at: payload.startIndex))
    }

    var terminalSize: (columns: UInt16, rows: UInt16)? {
        guard kind == .resize, payload.count >= 4 else { return nil }
        return (payload.littleEndianUInt16(at: payload.startIndex), payload.littleEndianUInt16(at: payload.startIndex + 2))
    }

    var text: String { String(decoding: payload, as: UTF8.self) }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at index: Index) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[index + $1]) << (8 * $1) }
    }

    func littleEndianUInt16(at index: Index) -> UInt16 {
        UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }
}

/// A problem with the frames that the agent or Hypervisaur sent.
public struct GuestAgentError: LocalizedError {
    public var errorDescription: String?

    public init(_ description: String) {
        errorDescription = description
    }
}
