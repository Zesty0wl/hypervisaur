import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VirtualCore

/// Pictures from a guest can claim any size or resolution, so neither should decide how much work the host does.
struct GuestPictureTests {
    /// A PNG of `pixels` square that says it's `dotsPerInch`, which is what decides the size `NSImage` gives it in points.
    private func picture(pixels: Int, dotsPerInch: Double) throws -> Data {
        let context = try #require(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let image = try #require(context.makeImage())

        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dotsPerInch, kCGImagePropertyDPIHeight: dotsPerInch] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func imagesSmallerThanAPointStillGetAHash() throws {
        let image = try #require(NSImage(data: try picture(pixels: 1, dotsPerInch: 1000)))
        #expect(image.size.width < 1)

        #expect(image.blurHash(numberOfComponents: (4, 4)) != nil)
    }

    @Test func imagesClaimingToBeHugeAreHashedQuickly() throws {
        let image = try #require(NSImage(data: try picture(pixels: 64, dotsPerInch: 0.72)))
        #expect(image.size.width >= 6400)

        let clock = ContinuousClock()
        let start = clock.now
        let hash = image.blurHash(numberOfComponents: (4, 4))
        let elapsed = clock.now - start

        #expect(hash != nil)
        #expect(elapsed < .seconds(1))
    }

    @Test func thumbnailsAreBoundedWhateverTheImageClaims() throws {
        for data in [try picture(pixels: 2048, dotsPerInch: 72), try picture(pixels: 64, dotsPerInch: 0.72)] {
            let thumbnail = try #require(CGImage.vb_thumbnail(from: data, maxPixelSize: 512))
            #expect(max(thumbnail.width, thumbnail.height) <= 512)
        }
    }

    @Test func dataThatIsntAnImageHasNoThumbnail() {
        #expect(CGImage.vb_thumbnail(from: Data("not an image".utf8)) == nil)
        #expect(CGImage.vb_thumbnail(from: Data()) == nil)
    }
}
