import Foundation
import CoreGraphics
import OSLog

/// Minimal RFB client used to display and control a QEMU virtual machine over a local socket.
///
/// Only the raw encoding is used since the connection never leaves the machine.
/// Keyboard input uses QEMU's extended key event, which carries scancodes instead of keysyms,
/// so the guest receives the physical keys regardless of the host's keyboard layout.
public final class VNCClient: @unchecked Sendable {
    public struct PointerButtons: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let left = PointerButtons(rawValue: 1 << 0)
        public static let middle = PointerButtons(rawValue: 1 << 1)
        public static let right = PointerButtons(rawValue: 1 << 2)
        public static let wheelUp = PointerButtons(rawValue: 1 << 3)
        public static let wheelDown = PointerButtons(rawValue: 1 << 4)
        public static let wheelLeft = PointerButtons(rawValue: 1 << 5)
        public static let wheelRight = PointerButtons(rawValue: 1 << 6)
    }

    private enum Encoding: Int32 {
        case raw = 0
        case desktopSize = -223
        case qemuExtendedKeyEvent = -258
    }

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "VNCClient")

    private let connection: UnixSocketConnection

    private let stateLock = NSLock()
    private var framebufferWidth: Int
    private var framebufferHeight: Int
    private var framebuffer: [UInt8]
    private var pendingFrame: CGImage?
    private var isFrameDeliveryScheduled = false

    /// Called on the main queue with the most recent frame. Frames produced while the main queue is busy are dropped.
    public var onFrame: ((CGImage) -> Void)?

    /// Called on the main queue once when the connection ends.
    public var onDisconnect: ((Error?) -> Void)?

    public var framebufferSize: CGSize {
        stateLock.withLock { CGSize(width: framebufferWidth, height: framebufferHeight) }
    }

    private init(connection: UnixSocketConnection, width: Int, height: Int) {
        self.connection = connection
        self.framebufferWidth = width
        self.framebufferHeight = height
        self.framebuffer = [UInt8](repeating: 0, count: width * height * 4)
    }

    static func connect(path: String, timeout: Duration) async throws -> VNCClient {
        let connection = try await UnixSocketConnection.connect(path: path, timeout: timeout)

        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let (width, height) = try Self.handshake(on: connection)
                    continuation.resume(returning: VNCClient(connection: connection, width: width, height: height))
                } catch {
                    connection.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() {
        let thread = Thread { [self] in
            do {
                try configureSession()
                try runReceiveLoop()
            } catch {
                logger.debug("VNC connection ended: \(error, privacy: .public)")
                DispatchQueue.main.async { [self] in
                    onDisconnect?(error)
                    onDisconnect = nil
                }
            }
        }
        thread.name = "VNCClient"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func close() {
        connection.close()
    }

    // MARK: - Input

    /// Sends a key press or release using a QEMU key number (an XT scancode, with `0x80` set for extended keys).
    public func sendKey(_ keyNumber: UInt32, isDown: Bool) {
        var message = Data([255, 0])
        message.appendBigEndian(UInt16(isDown ? 1 : 0))
        message.appendBigEndian(UInt32(0))
        message.appendBigEndian(keyNumber)
        send(message)
    }

    /// Sends the pointer position in framebuffer coordinates along with the buttons that are currently pressed.
    public func sendPointer(x: Int, y: Int, buttons: PointerButtons) {
        let size = framebufferSize
        let clampedX = UInt16(clamping: min(max(x, 0), max(Int(size.width) - 1, 0)))
        let clampedY = UInt16(clamping: min(max(y, 0), max(Int(size.height) - 1, 0)))

        var message = Data([5, buttons.rawValue])
        message.appendBigEndian(clampedX)
        message.appendBigEndian(clampedY)
        send(message)
    }

    private func send(_ data: Data) {
        do {
            try connection.write(data)
        } catch {
            logger.debug("Failed to send VNC message: \(error, privacy: .public)")
        }
    }

    // MARK: - Protocol

    private static func handshake(on connection: UnixSocketConnection) throws -> (Int, Int) {
        let version = try connection.read(exactly: 12)
        guard version.starts(with: Data("RFB 003.".utf8)) else {
            throw Failure("Unexpected response from the virtual machine's display server.")
        }
        try connection.write(Data("RFB 003.008\n".utf8))

        let securityTypeCount = Int(try connection.readByte())
        guard securityTypeCount > 0 else {
            let reasonLength = try connection.read(exactly: 4).bigEndianUInt32(at: 0)
            let reason = try connection.read(exactly: Int(reasonLength))
            throw Failure("The display server refused the connection: \(String(decoding: reason, as: UTF8.self))")
        }

        let securityTypes = try connection.read(exactly: securityTypeCount)
        guard securityTypes.contains(1) else {
            throw Failure("The display server requires authentication, which isn't supported.")
        }
        try connection.write(Data([1]))

        let securityResult = try connection.read(exactly: 4).bigEndianUInt32(at: 0)
        guard securityResult == 0 else {
            throw Failure("The display server rejected the connection.")
        }

        /// Shared flag, other clients such as a debugging VNC viewer may stay connected.
        try connection.write(Data([1]))

        let serverInit = try connection.read(exactly: 24)
        let width = Int(serverInit.bigEndianUInt16(at: 0))
        let height = Int(serverInit.bigEndianUInt16(at: 2))
        let nameLength = Int(serverInit.bigEndianUInt32(at: 20))
        _ = try connection.read(exactly: nameLength)

        return (width, height)
    }

    private func configureSession() throws {
        /// 32 bits per pixel, little-endian, true color with red/green/blue in bits 16/8/0, which is BGRA in memory.
        var pixelFormat = Data([0, 0, 0, 0])
        pixelFormat.append(contentsOf: [32, 24, 0, 1])
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.append(contentsOf: [16, 8, 0, 0, 0, 0])
        try connection.write(pixelFormat)

        let encodings: [Encoding] = [.raw, .desktopSize, .qemuExtendedKeyEvent]
        var setEncodings = Data([2, 0])
        setEncodings.appendBigEndian(UInt16(encodings.count))
        for encoding in encodings {
            setEncodings.appendBigEndian(UInt32(bitPattern: encoding.rawValue))
        }
        try connection.write(setEncodings)

        try requestUpdate(incremental: false)
    }

    private func requestUpdate(incremental: Bool) throws {
        let (width, height) = stateLock.withLock { (framebufferWidth, framebufferHeight) }

        var message = Data([3, incremental ? 1 : 0])
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(clamping: width))
        message.appendBigEndian(UInt16(clamping: height))
        try connection.write(message)
    }

    private func runReceiveLoop() throws {
        while true {
            let messageType = try connection.readByte()

            switch messageType {
            case 0:
                try receiveFramebufferUpdate()
            case 1:
                let header = try connection.read(exactly: 5)
                let colorCount = Int(header.bigEndianUInt16(at: 3))
                _ = try connection.read(exactly: colorCount * 6)
            case 2:
                break
            case 3:
                let header = try connection.read(exactly: 7)
                let length = Int(header.bigEndianUInt32(at: 3))
                _ = try connection.read(exactly: length)
            default:
                throw Failure("Unsupported message type \(messageType) from the display server.")
            }
        }
    }

    private func receiveFramebufferUpdate() throws {
        let header = try connection.read(exactly: 3)
        let rectangleCount = Int(header.bigEndianUInt16(at: 1))

        var needsFullUpdate = false

        for _ in 0..<rectangleCount {
            let rectangle = try connection.read(exactly: 12)
            let x = Int(rectangle.bigEndianUInt16(at: 0))
            let y = Int(rectangle.bigEndianUInt16(at: 2))
            let width = Int(rectangle.bigEndianUInt16(at: 4))
            let height = Int(rectangle.bigEndianUInt16(at: 6))
            let encoding = Int32(bitPattern: rectangle.bigEndianUInt32(at: 8))

            switch Encoding(rawValue: encoding) {
            case .raw:
                try receiveRawRectangle(x: x, y: y, width: width, height: height)
            case .desktopSize:
                resizeFramebuffer(width: width, height: height)
                needsFullUpdate = true
            case .qemuExtendedKeyEvent:
                break
            case .none:
                throw Failure("Unsupported encoding \(encoding) from the display server.")
            }
        }

        publishFrame()

        try requestUpdate(incremental: !needsFullUpdate)
    }

    private func receiveRawRectangle(x: Int, y: Int, width: Int, height: Int) throws {
        let rowLength = width * 4
        let data = try connection.read(exactly: rowLength * height)

        stateLock.withLock {
            guard x + width <= framebufferWidth, y + height <= framebufferHeight else { return }

            data.withUnsafeBytes { source in
                framebuffer.withUnsafeMutableBytes { destination in
                    for row in 0..<height {
                        let destinationOffset = ((y + row) * framebufferWidth + x) * 4
                        let sourceOffset = row * rowLength
                        destination.baseAddress!.advanced(by: destinationOffset)
                            .copyMemory(from: source.baseAddress!.advanced(by: sourceOffset), byteCount: rowLength)
                    }
                }
            }
        }
    }

    private func resizeFramebuffer(width: Int, height: Int) {
        stateLock.withLock {
            framebufferWidth = width
            framebufferHeight = height
            framebuffer = [UInt8](repeating: 0, count: width * height * 4)
        }
    }

    private func publishFrame() {
        let shouldSchedule: Bool = stateLock.withLock {
            guard framebufferWidth > 0, framebufferHeight > 0 else { return false }

            let data = Data(framebuffer) as CFData
            guard let provider = CGDataProvider(data: data),
                  let image = CGImage(
                    width: framebufferWidth,
                    height: framebufferHeight,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: framebufferWidth * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  )
            else { return false }

            pendingFrame = image

            guard !isFrameDeliveryScheduled else { return false }
            isFrameDeliveryScheduled = true
            return true
        }

        guard shouldSchedule else { return }

        DispatchQueue.main.async { [self] in
            let frame: CGImage? = stateLock.withLock {
                isFrameDeliveryScheduled = false
                defer { pendingFrame = nil }
                return pendingFrame
            }
            guard let frame else { return }
            onFrame?(frame)
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func bigEndianUInt16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) << 8 | UInt16(self[start + 1])
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) << 24 | UInt32(self[start + 1]) << 16 | UInt32(self[start + 2]) << 8 | UInt32(self[start + 3])
    }
}
