import Foundation

/// Combination of blur hash number of components with the blur hash string itself.
///
/// This is used when a blur hash must be stored and it's possible that the number of components
/// will change between different sources of the blur hash, ensuring that clients rendering the blur hash
/// image always use the correct number of components.
public struct BlurHashToken: Hashable, Codable, Sendable, ProvidesEmptyPlaceholder {
    public var value: String
    public var size: Int

    public init(value: String, size: Int = .vbBlurHashSize) {
        self.value = value
        self.size = size
    }

    public static let empty = BlurHashToken.virtualBuddyBackground
}

public extension Int {
    /// The size of blur hash used by VirtualBuddy.
    static let vbBlurHashSize = 4
}

public extension BlurHashToken {
    /// Hardcoded Hypervisaur teal to navy background blur hash.
    static let virtualBuddyBackground = BlurHashToken(
        value: "UJ2vTLlmkVkWl-kqj[fkkWj[fQfQkWfkfPfR",
        size: 4
    )

    /// Hardcoded VirtualBuddy background blur hash for Linux VMs.
    static let virtualBuddyBackgroundLinux = BlurHashToken(
        value: "UsLn]CG1I;t19uxAR$jJOXjEj=ayn%fkjubI",
        size: 4
    )

    /// Hardcoded VirtualBuddy background blur hash for Windows VMs.
    static let virtualBuddyBackgroundWindows = BlurHashToken(
        value: "Uh3CSYpyaKaLpfkqaeaea0aKkCkCaMaLkCkB",
        size: 4
    )
}

public extension VBGuestType {
    /// The background for virtual machines of this type that don't have artwork of their own.
    var defaultBackgroundHash: BlurHashToken {
        switch self {
        case .mac: .virtualBuddyBackground
        case .linux: .virtualBuddyBackgroundLinux
        case .windows: .virtualBuddyBackgroundWindows
        }
    }
}
