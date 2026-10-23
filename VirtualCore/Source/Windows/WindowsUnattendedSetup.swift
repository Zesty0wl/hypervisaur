import Foundation

/// What Windows Setup needs to install Windows and sign in to a local account without asking anything.
///
/// Without these settings, Windows Setup asks which edition to install and where, then the first-run setup asks
/// for a Microsoft account and the usual privacy choices.
public struct WindowsUnattendedSetup: Codable, Hashable, Sendable {
    /// The name of the local administrator account that's created and signed in to.
    public var accountName: String
    /// The account's password, or `nil` for an account without a password.
    ///
    /// Windows signs in to an account without a password every time it starts. When there's a password,
    /// it only signs in by itself the first time, so that the password isn't kept in the registry afterwards.
    public var password: String?
    /// The language and region for formats, the keyboard and programs that don't support Unicode, such as `en-GB`.
    public var locale: String
    /// The Windows name of the time zone, such as `GMT Standard Time`, or `nil` to leave Windows' default.
    public var timeZone: String?

    public init(accountName: String, password: String? = nil, locale: String = Self.hostLocale, timeZone: String? = Self.hostTimeZone) {
        self.accountName = accountName
        self.password = password.flatMap { $0.isEmpty ? nil : $0 }
        self.locale = locale
        self.timeZone = timeZone
    }

    /// The Mac account's short name, which is usually also valid for Windows.
    public static var defaultAccountName: String { String(NSUserName().prefix(20)) }

    /// Windows' rules for the names of local accounts.
    public static func validateAccountName(_ name: String) throws {
        guard !name.isEmpty else {
            throw Failure("Enter a name for the Windows account.")
        }
        guard name.count <= 20 else {
            throw Failure("Windows account names can’t be longer than 20 characters.")
        }
        if let character = name.first(where: { Self.disallowedAccountNameCharacters.contains($0) || $0.isNewline || $0.asciiValue.map({ $0 < 32 }) == true }) {
            throw Failure("Windows account names can’t contain “\(character)”.")
        }
        guard !name.allSatisfy({ $0 == "." || $0 == " " }) else {
            throw Failure("Windows account names can’t consist only of periods and spaces.")
        }
        guard !Self.reservedAccountNames.contains(name.lowercased()) else {
            throw Failure("“\(name)” is reserved by Windows. Choose a different account name.")
        }
    }

    private static let disallowedAccountNameCharacters = Set("\"/\\[]:;|=,+*?<>@")

    private static let reservedAccountNames: Set<String> = ["administrator", "guest", "defaultaccount", "wdagutilityaccount", "system", "none"]

    /// The Mac's language and region as a locale name that Windows recognizes.
    public static var hostLocale: String {
        let language = Locale.current.language
        guard let code = language.languageCode?.identifier else { return "en-US" }
        guard let region = Locale.current.region?.identifier else { return code }
        return "\(code)-\(region)"
    }

    /// The Mac's time zone as Windows names it.
    public static var hostTimeZone: String? {
        WindowsTimeZone.name(forIdentifier: TimeZone.current.identifier)
    }
}

public extension VBVirtualMachine {
    /// The settings for installing Windows without interaction. It's removed once Windows has been installed,
    /// since it may contain the account's password.
    var windowsUnattendedSetupURL: URL { metadataDirectoryURL.appending(path: "WindowsSetup.plist") }

    func windowsUnattendedSetup() throws -> WindowsUnattendedSetup? {
        guard FileManager.default.fileExists(atPath: windowsUnattendedSetupURL.path) else { return nil }

        let data = try Data(contentsOf: windowsUnattendedSetupURL)
        return try PropertyListDecoder().decode(WindowsUnattendedSetup.self, from: data)
    }

    func saveWindowsUnattendedSetup(_ setup: WindowsUnattendedSetup) throws {
        let data = try PropertyListEncoder().encode(setup)
        try data.write(to: windowsUnattendedSetupURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: windowsUnattendedSetupURL.path)
    }

    func removeWindowsUnattendedSetup() throws {
        guard FileManager.default.fileExists(atPath: windowsUnattendedSetupURL.path) else { return }
        try FileManager.default.removeItem(at: windowsUnattendedSetupURL)
    }
}
