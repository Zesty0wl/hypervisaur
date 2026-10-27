import Foundation
import Darwin
import VirtualWormhole

/// Shares the Mac's folders with a Windows virtual machine over SMB, using Samba from Homebrew.
///
/// QEMU on the Mac has no virtiofs device, but Windows connects to SMB shares by itself. For each connection that Windows makes
/// to ``serverAddress``, QEMU's user networking starts Samba with the configuration that this writes to QEMU's runtime
/// directory. The server is only reachable from the virtual machine, and only runs while Windows is connected to it.
///
/// Each folder is a share of its own, named after the folder, which Windows shows as a network drive, and which can be
/// read-only on its own. A single share with a DFS link to each folder's share would show them in one drive, but Samba opens
/// DFS links themselves instead of referring Windows to their shares when Windows asks for them as reparse points, which it does.
/// Windows 11 doesn't connect to shares as a guest, or without signing, so the shares have a user of their own, ``userName``,
/// which Samba maps to the Mac's user, with a password that's kept with the virtual machine. The Hypervisaur agent in Windows
/// connects to the shares with them.
struct WindowsFolderSharing {
    /// The address in the virtual machine where the Mac serves its folders, which QEMU's user networking doesn't use for anything else.
    static let serverAddress = "10.0.2.4"

    static let userName = "hypervisaur"

    /// Tells the agent that nothing is shared, so that it disconnects Windows from the server.
    static let nothingShared = GuestSharedFolders(server: serverAddress, credentials: nil, shareNames: [])

    /// Homebrew installs Samba's server with this name, so that it doesn't conflict with the Mac's own `smbd`.
    static func serverURL(in homebrew: Homebrew) -> URL {
        homebrew.prefix.appending(path: "sbin/samba-dot-org-smbd")
    }

    struct Share: Equatable {
        /// The share's name, which Windows shows for its drive.
        var name: String
        /// The name of the link to the folder in Samba's directory, which is the share's path.
        var linkName: String
        var url: URL
        var isReadOnly: Bool
    }

    let directoryURL: URL
    let serverURL: URL
    let password: String
    let shares: [Share]

    /// What the agent needs to connect Windows to the shares.
    var sharedFolders: GuestSharedFolders {
        GuestSharedFolders(server: Self.serverAddress, credentials: .init(userName: Self.userName, password: password), shareNames: shares.map(\.name))
    }

    var configurationURL: URL { directoryURL.appending(path: "smb.conf") }

    /// What QEMU runs for each connection to the server. Samba serves the connection on its standard input and output.
    var serverCommand: String {
        [serverURL.path, "--configfile=\(configurationURL.path)"].map(\.shellQuoted).joined(separator: " ")
    }

    /// Sets up Samba to share the virtual machine's folders in a directory of its own in QEMU's runtime directory.
    /// Returns `nil` if nothing is shared, if the virtual machine has no network to reach the server over, or if Samba isn't installed.
    static func prepare(for model: VBVirtualMachine, in runtimeDirectoryURL: URL) throws -> WindowsFolderSharing? {
        guard !VirtualBuddyManagedPreferences.sharedFoldersDisabled else {
            VirtualBuddyManagedPreferences.logger.notice("Host folder mappings ignored by DisableSharedFolders")
            return nil
        }

        let shares = shares(for: model.configuration.sharedFolders.filter { $0.isEnabled && $0.isAvailable })
        guard !shares.isEmpty, model.configuration.hardware.networkDevices.contains(where: { $0.kind == .NAT }) else { return nil }

        guard let homebrew = Homebrew.current, FileManager.default.isExecutableFile(atPath: serverURL(in: homebrew).path) else { return nil }

        let sharing = WindowsFolderSharing(
            directoryURL: runtimeDirectoryURL.appending(path: "samba", directoryHint: .isDirectory),
            serverURL: serverURL(in: homebrew),
            password: try password(for: model),
            shares: shares
        )
        try sharing.write(logURL: model.sambaLogURL)
        return sharing
    }

    /// Stops sharing the folders while the virtual machine runs, such as when an administrator disables shared folders.
    /// The servers that Windows is connected to are stopped, and the ones it starts afterwards don't have the folders.
    func stopSharing() throws {
        let fileManager = FileManager.default

        try Data(Self.configuration(directoryURL: directoryURL, unixUserName: NSUserName(), shares: []).utf8).write(to: configurationURL, options: .atomic)

        for item in try fileManager.contentsOfDirectory(at: foldersURL, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: item)
        }

        /// Each Samba process has a file named after its process identifier here, for messages from the others.
        let processesURL = directoryURL.appending(path: "lock/msg.lock", directoryHint: .isDirectory)
        for name in (try? fileManager.contentsOfDirectory(atPath: processesURL.path)) ?? [] {
            guard let pid = pid_t(name), Self.isSambaProcess(pid) else { continue }
            kill(pid, SIGTERM)
        }
    }

    // MARK: - Files

    private var foldersURL: URL { directoryURL.appending(path: "folders", directoryHint: .isDirectory) }
    private var privateURL: URL { directoryURL.appending(path: "private", directoryHint: .isDirectory) }

    /// Samba's paths are all in the runtime directory: values in its configuration can't be quoted, and it expands `%` in them.
    /// So the shares' paths are links to the folders, and the log is a link to the one in the virtual machine's bundle.
    private func write(logURL: URL) throws {
        let fileManager = FileManager.default

        for name in Self.stateDirectoryNames {
            try fileManager.createDirectory(at: directoryURL.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.createDirectory(at: foldersURL, withIntermediateDirectories: true)

        for share in shares {
            try fileManager.createSymbolicLink(at: foldersURL.appending(path: share.linkName), withDestinationURL: share.url)
        }

        let passwordLine = Self.passwordFileLine(unixUserName: NSUserName(), userID: getuid(), password: password, changed: .now)
        guard fileManager.createFile(atPath: privateURL.appending(path: "smbpasswd").path, contents: Data(passwordLine.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Couldn’t write the password for shared folders.")
        }

        try Data("\(NSUserName()) = \(Self.userName)\n".utf8).write(to: directoryURL.appending(path: "users.map"))

        /// The log starts afresh each time the virtual machine starts, like QEMU's.
        fileManager.createFile(atPath: logURL.path, contents: nil)
        try fileManager.createSymbolicLink(at: directoryURL.appending(path: "smbd.log"), withDestinationURL: logURL)

        try Data(Self.configuration(directoryURL: directoryURL, unixUserName: NSUserName(), shares: shares).utf8).write(to: configurationURL)
    }

    private static let stateDirectoryNames = ["private", "lock", "state", "cache", "pid", "ncalrpc"]

    static func configuration(directoryURL: URL, unixUserName: String, shares: [Share]) -> String {
        func path(_ name: String) -> String { directoryURL.appending(path: name).path }

        var lines = [
            "[global]",
            "private dir = \(path("private"))",
            "lock directory = \(path("lock"))",
            "state directory = \(path("state"))",
            "cache directory = \(path("cache"))",
            "pid directory = \(path("pid"))",
            "ncalrpc dir = \(path("ncalrpc"))",
            "log file = \(path("smbd.log"))",
            "max log size = 0",
            "log level = 1",
            "passdb backend = smbpasswd:\(path("private/smbpasswd"))",
            "username map = \(path("users.map"))",
            "security = user",
            "map to guest = never",
            "restrict anonymous = 2",
            "valid users = \(unixUserName)",
            "server min protocol = SMB3",
            "server signing = mandatory",
            "disable netbios = yes",
            "load printers = no",
            "printing = bsd",
            "printcap name = /dev/null",
            "disable spoolss = yes",
            "usershare max shares = 0",
            "host msdfs = no",
            /// The Mac doesn't have the mutexes that Samba would use for its databases, which it would log each time it starts.
            "dbwrap_tdb_mutexes:* = no",
            /// Windows' attributes would otherwise be kept in extended attributes, or in permissions, of the Mac's files.
            "store dos attributes = no",
            "ea support = no",
            "map archive = no",
            "map hidden = no",
            "map system = no",
            "map readonly = no",
        ]

        for share in shares {
            lines += [
                "",
                "[\(share.name)]",
                "path = \(path("folders/\(share.linkName)"))",
                "read only = \(share.isReadOnly ? "yes" : "no")",
            ]
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Each folder's share is named after the folder, as far as share names allow, and differently from the others.
    /// Its link is named after the folder's identifier, which never changes.
    static func shares(for folders: [VBSharedFolder]) -> [Share] {
        var usedNames = reservedShareNames

        return folders.map { folder in
            let baseName = shareName(for: folder.effectiveMountPointName)
            var name = baseName
            var number = 2
            while usedNames.contains(name.lowercased()) {
                let suffix = " \(number)"
                name = String(baseName.prefix(maximumShareNameLength - suffix.count)) + suffix
                number += 1
            }
            usedNames.insert(name.lowercased())

            let identifier = folder.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return Share(name: name, linkName: identifier, url: folder.url, isReadOnly: folder.isReadOnly)
        }
    }

    /// Samba gives these sections of its configuration meanings of their own, and Windows uses `IPC$` itself.
    private static let reservedShareNames: Set<String> = ["global", "homes", "printers", "print$", "ipc$"]

    private static let maximumShareNameLength = 80

    /// Characters that Windows doesn't allow in share names become `_`, and so do `[`, `]` and `%`, which Samba's configuration
    /// gives meanings of their own. Spaces at either end are removed, since Samba ignores them.
    static func shareName(for name: String) -> String {
        let disallowed = CharacterSet(charactersIn: #"\/[]:|<>+=;,*?"%"#).union(.controlCharacters)
        let result = String(String.UnicodeScalarView(name.unicodeScalars.map { disallowed.contains($0) ? "_" : $0 }))
            .trimmingCharacters(in: .whitespaces)
            .prefix(maximumShareNameLength)
            .trimmingCharacters(in: .whitespaces)

        return result.isEmpty ? "Folder" : result
    }

    // MARK: - Password

    /// Samba's password file has the NT hash of the password, which is the MD4 digest of it in UTF-16. The `X` flag keeps the
    /// password from expiring.
    static func passwordFileLine(unixUserName: String, userID: uid_t, password: String, changed: Date) -> String {
        let hash = MD4.hash(Data(password.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
            .map { String(format: "%02X", $0) }
            .joined()
        let changedTime = String(format: "%08X", UInt32(clamping: Int(changed.timeIntervalSince1970)))
        return "\(unixUserName):\(userID):\(String(repeating: "X", count: 32)):\(hash):[UX         ]:LCT-\(changedTime):\n"
    }

    /// The password is made when folders are first shared with the virtual machine, and Windows keeps it to connect again.
    private static func password(for model: VBVirtualMachine) throws -> String {
        let url = model.sharedFoldersPasswordURL

        if let password = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
            return password
        }

        let characters = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        let password = String((0..<32).map { _ in characters.randomElement(using: &generator)! })

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(password.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Couldn’t save the password for shared folders in the virtual machine.")
        }

        return password
    }

    private static func isSambaProcess(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let name = URL(filePath: String(cString: buffer)).lastPathComponent
        return name == "samba-dot-org-smbd" || name == "samba-dcerpcd" || name.hasPrefix("rpcd_")
    }
}

extension VBVirtualMachine {
    /// The password that Windows signs in to the shared folders with. See ``WindowsFolderSharing``.
    var sharedFoldersPasswordURL: URL { metadataDirectoryURL.appending(path: "SharedFolders.password") }

    var sambaLogURL: URL { metadataDirectoryURL.appending(path: "samba.log") }
}

private extension String {
    /// Quotes the string for QEMU, which splits the command it runs for a connection into arguments the way a shell does.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
