import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The part of a window that shows a virtual machine's display, which is what screenshots and recordings capture.
public struct VMCaptureRegion: Equatable, @unchecked Sendable {
    /// The window's number in the window server.
    public let windowID: CGWindowID
    /// The display's area in the window, in points, with the origin at the window's top left corner.
    public let rect: CGRect

    @MainActor
    public init?(view: NSView) {
        guard let window = view.window, window.windowNumber > 0, !view.bounds.isEmpty else { return nil }

        let frame = view.convert(view.bounds, to: nil)

        self.windowID = CGWindowID(window.windowNumber)
        self.rect = CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height).integral
    }
}

/// Thrown when Hypervisaur isn't allowed to record the screen, which it needs to capture a virtual machine's window.
public struct ScreenCapturePermissionError: LocalizedError {
    public var errorDescription: String? {
        "Hypervisaur needs permission to record the screen to capture virtual machines. Allow Hypervisaur in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
    }

    /// Where the permission is given.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// Takes screenshots of virtual machines.
///
/// Guests that run in QEMU are captured from their display's frames, at the guest's resolution. Guests that run with
/// Virtualization only draw into their window, so they're captured from the window with ScreenCaptureKit, which needs
/// permission to record the screen.
public enum VMScreenCapture {
    @MainActor
    public static func screenshot(of runtime: VMRuntime, in region: VMCaptureRegion?) async throws -> CGImage {
        if let machine = runtime.qemuMachine {
            guard let frame = machine.latestFrame else {
                throw Failure("The virtual machine hasn’t shown anything on its display yet.")
            }
            return frame
        }

        guard let region else {
            throw Failure("The virtual machine’s display isn’t on screen.")
        }

        return try await screenshot(of: region)
    }

    /// A small picture of the virtual machine's display, for showing what it's doing at a glance.
    ///
    /// Unlike ``screenshot(of:in:)``, this never asks for anything: guests that are captured from their window only get a
    /// preview while it's on screen, and only once Hypervisaur is allowed to record the screen.
    /// - Returns: `nil` when there's nothing to show yet, or the display can't be captured without asking.
    @MainActor
    public static func preview(of runtime: VMRuntime, in region: VMCaptureRegion?, maxPixelSize: Int = previewMaxPixelSize) async -> CGImage? {
        if let machine = runtime.qemuMachine {
            guard let frame = machine.latestFrame else { return nil }
            return try? await performOffMainActor { frame.vb_scaledToFit(maxPixelSize: maxPixelSize) }
        }

        guard let region, CGPreflightScreenCaptureAccess() else { return nil }

        do {
            let filter = try await contentFilter(for: region)

            let configuration = SCStreamConfiguration()
            let scale = min(CGFloat(filter.pointPixelScale), CGFloat(maxPixelSize) / max(region.rect.width, region.rect.height))
            configure(configuration, for: region, scale: scale)
            configuration.showsCursor = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    /// The size of the longest side of previews, in pixels, which is plenty for the library.
    public static let previewMaxPixelSize = 640

    /// A screenshot of part of a window, without the pointer.
    public static func screenshot(of region: VMCaptureRegion) async throws -> CGImage {
        let filter = try await contentFilter(for: region)

        let configuration = SCStreamConfiguration()
        configure(configuration, for: region, scale: CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Writes an image to a PNG file, away from the main actor since large images take a moment to compress.
    public static func writePNG(_ image: CGImage, to url: URL) async throws {
        try await performOffMainActor { try writePNGSynchronously(image, to: url) }
    }

    private static func writePNGSynchronously(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("Couldn’t create \(url.lastPathComponent).")
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw Failure("Couldn’t write \(url.lastPathComponent).")
        }
    }

    // MARK: - ScreenCaptureKit

    /// Asks for permission to record the screen the first time, and throws if it hasn't been given.
    static func requireScreenCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenCapturePermissionError()
        }
    }

    /// Captures a window by itself, whether or not other windows cover it.
    static func contentFilter(for region: VMCaptureRegion) async throws -> SCContentFilter {
        try requireScreenCapturePermission()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == region.windowID }) else {
            throw Failure("The virtual machine’s window isn’t available to capture.")
        }

        return SCContentFilter(desktopIndependentWindow: window)
    }

    /// Captures the region at the size it has on screen, in pixels.
    static func configure(_ configuration: SCStreamConfiguration, for region: VMCaptureRegion, scale: CGFloat) {
        configuration.sourceRect = region.rect
        configuration.width = Int(region.rect.width * scale)
        configuration.height = Int(region.rect.height * scale)
        configuration.ignoreShadowsSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB
    }
}

/// Where screenshots and recordings of virtual machines are saved.
public enum VMCaptureLocation {
    /// The folder that macOS saves screenshots to, as chosen in the Screenshot app, or the desktop.
    public static var directoryURL: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            if url.isReadableDirectory {
                return url
            }
        }

        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// A file named after the virtual machine and the time, like the ones macOS makes, that doesn't exist yet.
    public static func newFileURL(for model: VBVirtualMachine, pathExtension: String, date: Date = .now, in directoryURL: URL = directoryURL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

        /// Slashes and colons can't be part of a file name in Finder.
        let name = model.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let baseName = "\(name) \(formatter.string(from: date))"

        var url = directoryURL.appending(path: "\(baseName).\(pathExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directoryURL.appending(path: "\(baseName) \(number).\(pathExtension)")
            number += 1
        }
        return url
    }
}

private extension CGImage {
    /// The image at a size whose longest side is at most the given number of pixels, or the image itself when it's already that small.
    func vb_scaledToFit(maxPixelSize: Int) -> CGImage? {
        let longestSide = max(width, height)
        guard longestSide > maxPixelSize else { return self }

        let scale = CGFloat(maxPixelSize) / CGFloat(longestSide)
        let size = CGSize(width: (CGFloat(width) * scale).rounded(), height: (CGFloat(height) * scale).rounded())

        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(origin: .zero, size: size))

        return context.makeImage()
    }
}
