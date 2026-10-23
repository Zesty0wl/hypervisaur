import Foundation

/// A small disk with the ``WindowsDrivers`` that's attached to Windows virtual machines.
///
/// The answer file on the installer disk runs the setup script on it at the end of Windows Setup. It stays attached afterwards
/// so that the script can be run in virtual machines that were set up without it.
enum WindowsDriversDisk {
    static let volumeName = "DRIVERS"
    static let driversFolderName = "VirtIODrivers"
    static let setupScriptName = "Setup.cmd"
    static let statusScriptName = "Status.cmd"

    /// Changes whenever the scripts on the disk change, so that disks with older scripts are created again.
    private static let layoutVersion = 4

    static var contentsVersion: String { "\(WindowsDrivers.contentsVersion)/\(layoutVersion)" }

    /// Installs the drivers, and tasks that tell VirtualBuddy when Windows has started and when someone has signed in.
    /// Running it in a virtual machine that was set up without it is how they're installed later.
    ///
    /// The tasks run as the system account, so that no window appears when they run.
    static let setupScript = """
    @echo off
    rem Installs the VirtIO drivers for Windows virtual machines in Hypervisaur.

    pnputil /add-driver "%~dp0*.inf" /subdirs /install

    set "StatusScript=%ProgramData%\\Hypervisaur\\\(statusScriptName)"
    mkdir "%ProgramData%\\Hypervisaur" 2>nul
    copy /y "%~dp0\(statusScriptName)" "%StatusScript%" >nul
    schtasks /create /f /tn "Hypervisaur\\Started" /sc onstart /ru SYSTEM /tr "%StatusScript% startup" >nul
    schtasks /create /f /tn "Hypervisaur\\Signed In" /sc onlogon /ru SYSTEM /tr "%StatusScript%" >nul

    exit /b 0

    """.windowsLineEndings

    /// Writes to the status port when Windows starts, and once someone has signed in and their desktop has started.
    /// See ``WindowsGuestStatus``.
    ///
    /// Windows Setup signs in to a temporary account to finish setting up, so the script also waits for Setup to have
    /// finished, and ignores that account's desktop. `timeout` doesn't work without a console, so `ping` waits between checks.
    static let statusScript = """
    @echo off
    rem Tells Hypervisaur when Windows has started, and when someone has signed in.

    if /i "%~1"=="startup" (
        echo \(WindowsGuestStatus.startedMessage)>\(statusPortPath)
        exit /b 0
    )

    for /l %%i in (1,1,300) do (
        reg query "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State" /v ImageState 2>nul | find "IMAGE_STATE_COMPLETE" >nul && tasklist /v /fo csv /nh /fi "imagename eq explorer.exe" 2>nul | find /i "explorer.exe" | find /i /v "defaultuser" >nul && goto signedin
        ping -n 3 127.0.0.1 >nul
    )
    exit /b 1

    :signedin
    echo \(WindowsGuestStatus.signedInMessage)>\(statusPortPath)
    exit /b 0

    """.windowsLineEndings

    private static let statusPortPath = "\\\\.\\Global\\\(WindowsGuestStatus.portName)"

    /// FAT32 volumes can't be smaller than this.
    private static let minimumSize: Int64 = 64 * 1024 * 1024

    /// Returns the drivers disk for the virtual machine, creating it if the drivers have changed since it was created,
    /// or `nil` if the drivers haven't been downloaded.
    static func prepare(for model: VBVirtualMachine) async throws -> URL? {
        guard WindowsDrivers.isInstalled else { return nil }

        let diskURL = model.windowsDriversDiskURL
        let versionURL = model.windowsDriversDiskVersionURL

        if FileManager.default.fileExists(atPath: diskURL.path),
           (try? String(contentsOf: versionURL, encoding: .utf8)) == contentsVersion {
            return diskURL
        }

        try await create(at: diskURL, from: WindowsDrivers.directoryURL)
        try Data(contentsVersion.utf8).write(to: versionURL, options: .atomic)

        return diskURL
    }

    static func create(at url: URL, from driversURL: URL) async throws {
        let size = max(minimumSize, try directorySize(driversURL) + 16 * 1024 * 1024)

        try await HostDiskImage.createFATDisk(at: url, size: size, volumeName: volumeName) { volumeURL in
            let destinationURL = volumeURL.appending(path: driversFolderName, directoryHint: .isDirectory)
            try await HostCommand.run("/usr/bin/rsync", ["-rt", "--exclude", "/.installed", driversURL.path + "/", destinationURL.path + "/"])
            try Data(setupScript.utf8).write(to: destinationURL.appending(path: setupScriptName))
            try Data(statusScript.utf8).write(to: destinationURL.appending(path: statusScriptName))
        }
    }

    private static func directorySize(_ url: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            size += Int64(try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        return size
    }
}

private extension String {
    /// Windows command scripts are expected to use Windows line endings.
    var windowsLineEndings: String { replacingOccurrences(of: "\n", with: "\r\n") }
}
