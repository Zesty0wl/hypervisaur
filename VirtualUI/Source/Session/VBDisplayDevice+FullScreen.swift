import AppKit
import VirtualCore

extension VBDisplayDevice {
    /// A display that fills the screen in full screen with as many pixels as the screen's panel has there, so that each of
    /// the guest's pixels is one of the panel's. On screens with a camera housing, full-screen windows stay below it.
    ///
    /// The panel's pixels aren't always the ones macOS draws: in scaled modes, such as one that looks like 3840 by 2160
    /// on a 4K screen, macOS draws twice as many and resamples them to fit the panel. The guest gets the panel's.
    ///
    /// The display keeps everything else from the virtual machine's own, such as whether it follows the size of the window,
    /// and macOS guests get the panel's pixel density, so that they look the same as the Mac does.
    static func filling(_ screen: NSScreen, basedOn display: VBDisplayDevice?) -> VBDisplayDevice {
        var result = display ?? VBDisplayDevice()

        let panelSize = screen.nativePixelSize
            ?? CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)

        /// Depending on the mode, the screen's frame may already leave out the band beside the camera housing, so the height
        /// comes from the shape of the area that full-screen windows get rather than from the panel's.
        let fullScreenHeight = screen.frame.height - screen.safeAreaInsets.top

        result.width = Self.evenPixelCount(panelSize.width)
        result.height = Self.evenPixelCount(panelSize.width * fullScreenHeight / screen.frame.width)

        if let millimetersWide = screen.physicalWidth {
            result.pixelsPerInch = Int((panelSize.width / (millimetersWide / 25.4)).rounded())
        }

        return result
    }

    /// Some guests only use display sizes with an even number of pixels.
    private static func evenPixelCount(_ value: CGFloat) -> Int {
        Int(value.rounded(.down)) & ~1
    }
}

private extension NSScreen {
    /// `kDisplayModeNativeFlag` from IOKit's `IOGraphicsTypes.h`, which marks the mode that matches the panel's pixels.
    static let displayModeNativeFlag: UInt32 = 0x0200_0000

    var screenDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The number of pixels the screen's panel has, or `nil` when the screen doesn't say which of its modes is the panel's.
    var nativePixelSize: CGSize? {
        guard let screenDisplayID else { return nil }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(screenDisplayID, options) as? [CGDisplayMode] ?? []

        guard let native = modes.filter({ $0.ioFlags & Self.displayModeNativeFlag != 0 }).max(by: { $0.pixelWidth < $1.pixelWidth }) else { return nil }

        return CGSize(width: native.pixelWidth, height: native.pixelHeight)
    }

    /// The width of the screen in millimetres, or `nil` when it doesn't say how big it is, as with some projectors.
    var physicalWidth: CGFloat? {
        guard let screenDisplayID else { return nil }
        let width = CGDisplayScreenSize(screenDisplayID).width
        return width > 0 ? width : nil
    }
}
