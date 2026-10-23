import Foundation

/// Maps time zone identifiers such as `Europe/London` to the names that Windows uses, such as `GMT Standard Time`.
///
/// The mapping comes from the Unicode CLDR data in ICU, which ships with macOS as `libicucore`. Its headers aren't
/// part of the SDK, so the function is looked up when it's first needed.
enum WindowsTimeZone {
    private typealias GetWindowsTimeZoneID = @convention(c) (
        _ id: UnsafePointer<UInt16>,
        _ length: Int32,
        _ windowsID: UnsafeMutablePointer<UInt16>,
        _ capacity: Int32,
        _ status: UnsafeMutablePointer<Int32>
    ) -> Int32

    private static let getWindowsTimeZoneID: GetWindowsTimeZoneID? = {
        guard let handle = dlopen("/usr/lib/libicucore.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "ucal_getWindowsTimeZoneID")
        else { return nil }

        return unsafeBitCast(symbol, to: GetWindowsTimeZoneID.self)
    }()

    static func name(forIdentifier identifier: String) -> String? {
        guard let getWindowsTimeZoneID else { return nil }

        let id = Array(identifier.utf16)
        var windowsID = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0

        let length = getWindowsTimeZoneID(id, Int32(id.count), &windowsID, Int32(windowsID.count), &status)

        /// ICU reports errors with positive status codes.
        guard status <= 0, length > 0, length <= windowsID.count else { return nil }

        return String(decoding: windowsID[..<Int(length)], as: UTF16.self)
    }
}
