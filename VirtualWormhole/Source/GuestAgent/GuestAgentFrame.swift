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
        /// Stops the program, or cancels a transfer.
        case terminate = 0x06
        /// Starts receiving files into the guest on a new channel. See ``GuestFileDestination``.
        case putFiles = 0x07
        /// Starts an item of a transfer, in either direction. See ``GuestFileHeader``.
        case fileHeader = 0x08
        /// The next bytes of the current file of a transfer, in either direction.
        case fileData = 0x09
        /// There are no more items in a transfer.
        case filesEnd = 0x0A
        /// Starts sending files from the guest on a new channel, with their paths in UTF-8, one per line.
        case getFiles = 0x0B
        /// How many bytes of file data the receiver of a transfer has written, as a `UInt64`.
        case acknowledge = 0x0C
        /// Asks the agent which files are being dragged in the guest, which it replies to with ``dragItems``.
        case catchDrag = 0x0D
        /// The size of a transfer, sent before its first item. See ``GuestTransferSize``.
        case transferSize = 0x0E
        /// Tells a Windows agent how to reach the folders that the Mac shares, on channel 0. See ``GuestSharedFolders``.
        case shareFolders = 0x0F

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
        /// Where the items of a ``putFiles`` transfer were put in the guest, as their paths in UTF-8, one per line.
        case transferred = 0x46
        /// The files being dragged in the guest. See ``GuestDragItem``.
        case dragItems = 0x47
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

    /// File data is sent in pieces of this size.
    public static let fileChunkSize = 256 * 1024

    /// The most file data that a sender has waiting to be acknowledged.
    public static let transferWindow: UInt64 = 4 << 20

    /// Receivers acknowledge file data at least this often, and after the last file.
    public static let acknowledgementInterval: UInt64 = 1 << 20

    /// The first protocol version with file transfers and drags.
    public static let fileTransferProtocolVersion: UInt32 = 2

    /// The first protocol version where Windows agents connect to the folders that the Mac shares.
    public static let sharedFoldersProtocolVersion: UInt32 = 4

    /// The virtio socket port that agents in Linux and macOS guests listen on, which is much faster than their other links.
    public static let socketPort: UInt32 = 51_781

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
    ///
    /// The decoded frames are removed from the buffer once, at the end, so that a batch of many frames takes time in
    /// proportion to its size.
    public mutating func decode(_ data: Data) throws -> [GuestAgentFrame] {
        buffer.append(data)

        var frames = [GuestAgentFrame]()
        var offset = buffer.startIndex
        defer { buffer.removeSubrange(buffer.startIndex..<offset) }

        while buffer.endIndex - offset >= GuestAgentFrame.headerSize {
            let length = Int(buffer.littleEndianUInt32(at: offset))

            guard length <= GuestAgentFrame.maximumPayloadSize else {
                throw GuestAgentError("The guest agent sent a message that's too large (\(length) bytes).")
            }

            let frameSize = GuestAgentFrame.headerSize + length
            guard buffer.endIndex - offset >= frameSize else { break }

            let kindValue = buffer[offset + 4]
            let channel = buffer.littleEndianUInt32(at: offset + 5)
            let payload = Data(buffer[(offset + GuestAgentFrame.headerSize)..<(offset + frameSize)])
            offset += frameSize

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

/// Where a Windows agent finds the folders that the Mac shares, and how it signs in to them.
///
/// Each folder is a share of its own on the Mac's server, which Windows shows as a network drive. Windows doesn't connect to
/// shares without signing in, so they have a user name and password of their own. When nothing is shared, there are no
/// credentials or shares, which tells the agent to disconnect from the server.
public struct GuestSharedFolders: Equatable, Sendable {
    public struct Credentials: Equatable, Sendable {
        public var userName: String
        public var password: String

        public init(userName: String, password: String) {
            self.userName = userName
            self.password = password
        }
    }

    /// The address of the Mac's server in the guest.
    public var server: String
    /// `nil` when nothing is shared.
    public var credentials: Credentials?
    /// The names of the shares, one for each folder, in the order the folders are listed on the Mac.
    public var shareNames: [String]

    public init(server: String, credentials: Credentials?, shareNames: [String]) {
        self.server = server
        self.credentials = credentials
        self.shareNames = shareNames
    }

    /// The server, then the user name, password and the share names when something is shared, in UTF-8, one per line.
    public var payload: Data {
        var lines = [server]
        if let credentials {
            lines += [credentials.userName, credentials.password] + shareNames
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    public init(payload: Data) throws {
        let lines = String(decoding: payload, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        switch lines.count {
        case 1:
            self.init(server: lines[0], credentials: nil, shareNames: [])
        case 3...:
            self.init(server: lines[0], credentials: Credentials(userName: lines[1], password: lines[2]), shareNames: Array(lines[3...]))
        default:
            throw GuestAgentError("The description of the shared folders is invalid.")
        }
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

    func littleEndianUInt64(at index: Index) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[index + $1]) << (8 * $1) }
    }
}

/// A problem with the frames that the agent or Hypervisaur sent.
public struct GuestAgentError: LocalizedError {
    public var errorDescription: String?

    public init(_ description: String) {
        errorDescription = description
    }
}
