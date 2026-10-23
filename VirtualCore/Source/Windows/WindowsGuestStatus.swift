import Foundation

/// What a Windows virtual machine is doing, as far as VirtualBuddy can tell from outside of it.
///
/// Windows reports when it has started and when someone has signed in by writing to a virtio serial port, which QEMU saves
/// to a file in the virtual machine's bundle. The file is emptied each time QEMU starts, but not when Windows restarts,
/// so the most recent message is what counts. See ``WindowsDriversDisk``.
public enum WindowsGuestStatus: String, Codable, Sendable {
    case stopped
    /// Windows Setup is running. After an unattended installation, this includes the restart that follows the first sign-in.
    /// Otherwise, the installer stays attached until the virtual machine next starts.
    case installing
    /// Windows is starting up, or waiting for someone to sign in.
    case starting
    /// Someone has signed in to Windows and the desktop has started.
    case signedIn

    static let portName = "virtualbuddy.status"
    static let startedMessage = "started"
    static let signedInMessage = "signed-in"

    public init(for model: VBVirtualMachine) {
        self.init(
            isRunning: model.qemuProcessIdentifier != nil,
            messages: (try? String(contentsOf: model.windowsGuestStatusURL, encoding: .utf8)) ?? "",
            isInstallerAttached: FileManager.default.fileExists(atPath: model.windowsInstallDiskURL.path),
            isUnattendedInstallation: FileManager.default.fileExists(atPath: model.windowsUnattendedSetupURL.path)
        )
    }

    /// - Parameter isUnattendedInstallation: Whether VirtualBuddy restarts the virtual machine once Windows has signed in
    ///   for the first time, which happens while the installer is still attached.
    init(isRunning: Bool, messages: String, isInstallerAttached: Bool, isUnattendedInstallation: Bool) {
        let isSignedIn = Self.lastMessage(in: messages) == Self.signedInMessage

        if !isRunning {
            self = .stopped
        } else if isSignedIn, !(isInstallerAttached && isUnattendedInstallation) {
            self = .signedIn
        } else if isInstallerAttached {
            self = .installing
        } else {
            self = .starting
        }
    }

    static func lastMessage(in messages: String) -> String? {
        messages.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces)
    }
}

public extension VBVirtualMachine {
    /// Where QEMU saves what Windows writes to the status port.
    var windowsGuestStatusURL: URL { metadataDirectoryURL.appending(path: "GuestStatus") }

    /// Written by QEMU while it runs the virtual machine, and removed when it exits.
    var qemuPIDFileURL: URL { metadataDirectoryURL.appending(path: "qemu.pid") }

    /// The process that runs the virtual machine, if it's running.
    var qemuProcessIdentifier: pid_t? {
        guard let contents = try? String(contentsOf: qemuPIDFileURL, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }

        /// The file is left behind if QEMU didn't exit normally, and its process ID may have been reused since.
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }

        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path).hasSuffix("/qemu-system-aarch64")
        else { return nil }

        return pid
    }
}
