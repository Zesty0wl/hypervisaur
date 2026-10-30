import Cocoa
import struct AVFoundation.AVFileType

public extension NSImage {
    static let defaultThumbnailProperties = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImageDestinationImageMaxPixelSize: 1024
    ] as CFDictionary

    static let defaultHEICProperties = [
        kCGImageDestinationLossyCompressionQuality: 1,
        kCGImageDestinationImageMaxPixelSize: 4096
    ] as CFDictionary

    // TODO: Adopt BuddyImageKit
    @discardableResult
    func vb_createThumbnail(at url: URL, options: CFDictionary = NSImage.defaultThumbnailProperties) throws -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure("Failed to create a CGImage")
        }

        try cgImage.vb_encodeHEIC(to: url, options: options)

        guard let thumbnailImage = NSImage(contentsOf: url) else {
            throw Failure("Failed to load generated thumbnail")
        }

        return thumbnailImage
    }

    // TODO: Adopt BuddyImageKit
    func vb_heicEncodedData(options: CFDictionary = NSImage.defaultHEICProperties) throws -> Data {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure("Failed to create a CGImage")
        }

        return try cgImage.vb_heicEncodedData(options: options)
    }

    // TODO: Adopt BuddyImageKit
    @discardableResult
    func vb_encodeHEIC(to url: URL, options: CFDictionary = NSImage.defaultHEICProperties) throws -> URL {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure("Failed to create a CGImage")
        }

        return try cgImage.vb_encodeHEIC(to: url, options: options)
    }
}

public extension CGImage {
    /// Decodes image data no larger than `maxPixelSize` on its longest side, whatever size or resolution it declares, for
    /// images that come from somewhere that isn't trusted, such as a guest.
    static func vb_thumbnail(from data: Data, maxPixelSize: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options), image.width > 0, image.height > 0 else { return nil }
        return image
    }

    // TODO: Adopt BuddyImageKit
    func vb_heicEncodedData(options: CFDictionary = NSImage.defaultHEICProperties) throws -> Data {
        guard let cfData = CFDataCreateMutable(kCFAllocatorDefault, 0) else {
            throw Failure("Failed to create CFMutableData")
        }
        guard let destination = CGImageDestinationCreateWithData(cfData, AVFileType.heic.rawValue as CFString, 1, nil) else {
            throw Failure("Failed to create image destination")
        }

        CGImageDestinationAddImage(destination, self, options)
        CGImageDestinationFinalize(destination)

        return cfData as Data
    }

    // TODO: Adopt BuddyImageKit
    @discardableResult
    func vb_encodeHEIC(to url: URL, options: CFDictionary = NSImage.defaultHEICProperties) throws -> URL {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, AVFileType.heic.rawValue as CFString, 1, nil) else {
            throw Failure("Failed to create image destination")
        }

        CGImageDestinationAddImage(destination, self, options)
        CGImageDestinationFinalize(destination)

        return url
    }
}
