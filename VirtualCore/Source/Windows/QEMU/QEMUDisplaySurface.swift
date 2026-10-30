import Foundation
import CoreGraphics
import Darwin

/// What the guest's display shows: memory that QEMU draws the guest's display into and shares with Hypervisaur, or that
/// holds what QEMU sends when it can't share it.
///
/// The memory is page-aligned and a whole number of pages long, so that the GPU can read the pixels where they are.
/// QEMU goes on drawing into shared memory while it's read, which is how a display works anyway.
public final class QEMUDisplaySurface: @unchecked Sendable {
    /// The order of each pixel's bytes in memory. Their fourth byte is ignored, since the guest's display is opaque.
    public enum PixelFormat: Sendable {
        case bgrx
        case rgbx

        /// Pixman's formats with 8 bits for each of red, green and blue, which are what QEMU uses for displays.
        /// QEMU always runs with the Mac's little-endian byte order.
        init?(pixmanFormat: UInt32) {
            switch pixmanFormat {
            case 0x2002_0888, 0x2002_8888: self = .bgrx
            case 0x2003_0888, 0x2003_8888: self = .rgbx
            default: return nil
            }
        }
    }

    /// The largest display that's accepted, which is more than any display QEMU supports.
    static let maximumDimension = 16_384

    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: PixelFormat
    /// Whether QEMU draws into the memory itself, rather than Hypervisaur copying what QEMU sends into it.
    public let isShared: Bool

    /// The start of the page-aligned memory, which the pixels start ``pixelOffset`` bytes into.
    public let memory: UnsafeMutableRawPointer
    /// How long the memory is, which is a whole number of pages.
    public let memoryLength: Int
    public let pixelOffset: Int

    public var pixels: UnsafeRawPointer { UnsafeRawPointer(memory.advanced(by: pixelOffset)) }

    private var pixelsLength: Int { bytesPerRow * height }

    /// Maps the memory that QEMU shares the guest's display in.
    ///
    /// - Parameter offset: Where the pixels start in the shared memory.
    init(sharedMemory descriptor: OwnedFileDescriptor, offset: Int, width: Int, height: Int, bytesPerRow: Int, pixmanFormat: UInt32) throws {
        let pixelFormat = try Self.validate(width: width, height: height, bytesPerRow: bytesPerRow, pixmanFormat: pixmanFormat)

        let (end, overflow) = offset.addingReportingOverflow(bytesPerRow * height)
        guard offset >= 0, !overflow else { throw Failure("QEMU shared a display that doesn’t fit in memory.") }

        /// Reading past the end of the shared file would crash, so it has to hold all of the pixels.
        var status = stat()
        guard fstat(descriptor.rawValue, &status) == 0 else { throw POSIXError.current }
        guard Int(status.st_size) >= end else {
            throw Failure("QEMU shared \(status.st_size) bytes for a display that needs \(end).")
        }

        let length = Self.roundedUpToPages(end)
        let memory = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor.rawValue, 0)
        guard let memory, memory != MAP_FAILED else { throw POSIXError.current }

        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.isShared = true
        self.memory = memory
        self.memoryLength = length
        self.pixelOffset = offset
    }

    /// Makes memory for the pixels that QEMU sends when it can't share them, which starts out black.
    init(width: Int, height: Int, bytesPerRow: Int, pixmanFormat: UInt32) throws {
        let pixelFormat = try Self.validate(width: width, height: height, bytesPerRow: bytesPerRow, pixmanFormat: pixmanFormat)

        let length = Self.roundedUpToPages(bytesPerRow * height)
        let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let memory, memory != MAP_FAILED else { throw POSIXError.current }

        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.isShared = false
        self.memory = memory
        self.memoryLength = length
        self.pixelOffset = 0
    }

    deinit {
        munmap(memory, memoryLength)
    }

    private static func validate(width: Int, height: Int, bytesPerRow: Int, pixmanFormat: UInt32) throws -> PixelFormat {
        guard let pixelFormat = PixelFormat(pixmanFormat: pixmanFormat) else {
            throw Failure("QEMU’s display uses pixel format \(String(pixmanFormat, radix: 16)), which isn’t supported.")
        }
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              bytesPerRow >= width * 4, bytesPerRow <= maximumDimension * 8
        else {
            throw Failure("QEMU’s display is \(width)×\(height) with \(bytesPerRow) bytes in each row, which isn’t supported.")
        }
        return pixelFormat
    }

    private static func roundedUpToPages(_ length: Int) -> Int {
        let pageSize = Int(getpagesize())
        return (length + pageSize - 1) / pageSize * pageSize
    }

    /// Copies pixels that QEMU sent into an area of the surface, as far as the area is inside it.
    ///
    /// Only surfaces that QEMU doesn't share can be written to.
    func write(_ data: Data, x: Int, y: Int, width: Int, height: Int, bytesPerRow sourceBytesPerRow: Int) {
        precondition(!isShared, "QEMU draws into shared surfaces itself.")

        let area = CGRect(x: x, y: y, width: width, height: height).intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return }

        let rowLength = Int(area.width) * 4
        let skippedRows = Int(area.minY) - y
        let skippedBytes = (Int(area.minX) - x) * 4

        data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }

            for row in 0..<Int(area.height) {
                let sourceOffset = (skippedRows + row) * sourceBytesPerRow + skippedBytes
                guard sourceOffset >= 0, sourceOffset + rowLength <= source.count else { return }

                let destinationOffset = pixelOffset + (Int(area.minY) + row) * bytesPerRow + Int(area.minX) * 4
                memory.advanced(by: destinationOffset).copyMemory(from: sourceBase.advanced(by: sourceOffset), byteCount: rowLength)
            }
        }
    }

    /// The whole surface, in its pixels.
    public var bounds: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// A copy of what the surface shows now, such as for a screenshot.
    public func makeImage() -> CGImage? {
        let data = Data(bytes: pixels, count: pixelsLength) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }

        let bitmapInfo = switch pixelFormat {
        case .bgrx: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case .rgbx: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// The pointer that the guest asks to be shown, which QEMU passes on separately from the display's pixels.
public struct QEMUCursor: @unchecked Sendable {
    /// The largest pointer that's accepted.
    static let maximumDimension = 512

    public var image: CGImage
    /// Where in the image the pointer points, in its pixels from the top left.
    public var hotSpot: CGPoint

    /// - Parameter pixels: 32-bit ARGB pixels, in the Mac's little-endian byte order, with alpha that isn't premultiplied.
    init(width: Int, height: Int, hotSpotX: Int, hotSpotY: Int, pixels: Data) throws {
        guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height),
              pixels.count == width * height * 4
        else {
            throw Failure("QEMU defined a \(width)×\(height) pointer with \(pixels.count) bytes of pixels.")
        }

        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw Failure("The guest’s pointer couldn’t be made into an image.")
        }

        self.image = image
        self.hotSpot = CGPoint(x: min(max(hotSpotX, 0), width - 1), y: min(max(hotSpotY, 0), height - 1))
    }
}
