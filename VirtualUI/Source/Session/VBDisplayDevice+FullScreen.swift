import AppKit
import VirtualCore

extension VBDisplayDevice {
    /// A display that fills the screen in full screen with as many pixels as the screen has there, so that each of the
    /// guest's pixels is one of the screen's. On screens with a camera housing, full-screen windows stay below it.
    ///
    /// The display keeps everything else from the virtual machine's own, such as whether it follows the size of the window,
    /// and macOS guests get the screen's pixel density, so that they look the same as the Mac does.
    static func filling(_ screen: NSScreen, basedOn display: VBDisplayDevice?) -> VBDisplayDevice {
        var result = display ?? VBDisplayDevice()

        let scale = screen.backingScaleFactor
        let pointSize = CGSize(width: screen.frame.width, height: screen.frame.height - screen.safeAreaInsets.top)

        result.width = Self.evenPixelCount(pointSize.width * scale)
        result.height = Self.evenPixelCount(pointSize.height * scale)

        if let pixelsPerInch = screen.pixelsPerInch {
            result.pixelsPerInch = pixelsPerInch
        }

        return result
    }

    /// Some guests only use display sizes with an even number of pixels.
    private static func evenPixelCount(_ value: CGFloat) -> Int {
        Int(value.rounded(.down)) & ~1
    }
}

private extension NSScreen {
    /// The density of the screen's backing pixels, which are what a full-screen guest gets, or `nil` when the screen doesn't
    /// say how big it is, as with some projectors.
    var pixelsPerInch: Int? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }

        let millimetersWide = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value)).width
        guard millimetersWide > 0 else { return nil }

        return Int((frame.width * backingScaleFactor / (millimetersWide / 25.4)).rounded())
    }
}
