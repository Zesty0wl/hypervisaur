import Foundation

/// A resolution a guest's display can be switched to.
public struct GuestDisplayResolution: Hashable, Comparable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.width, lhs.height) < (rhs.width, rhs.height)
    }

    /// Resolutions that are offered for displays that can be switched to any resolution, such as those of Virtualization.
    static let common: [GuestDisplayResolution] = [
        (1280, 720), (1280, 800), (1440, 900), (1600, 900), (1680, 1050), (1920, 1080), (1920, 1200),
        (2560, 1440), (2560, 1600), (2880, 1800), (3840, 2160),
    ].map { GuestDisplayResolution(width: $0.0, height: $0.1) }

    /// Parses `1920x1080`.
    init?(_ text: some StringProtocol) {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        self.init(width: width, height: height)
    }
}

/// The resolutions a guest's display can be switched to, and the one it's using.
public struct GuestDisplayModes: Hashable, Sendable {
    public var current: GuestDisplayResolution?
    public var available: [GuestDisplayResolution]

    public init(current: GuestDisplayResolution?, available: [GuestDisplayResolution]) {
        self.current = current
        self.available = available
    }
}
