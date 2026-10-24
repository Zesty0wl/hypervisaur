import Foundation

/// A small disk with the ``WindowsDrivers`` that's attached to Windows virtual machines.
///
/// The answer file on the installer disk runs the setup script on it at the end of Windows Setup. It stays attached afterwards
/// so that the script can be run in virtual machines that were set up without it, and so that Windows runs it again when it
/// starts if the disk has a newer version than the one that was last run.
enum WindowsDriversDisk {
    static let volumeName = "DRIVERS"
    static let driversFolderName = "VirtIODrivers"
    static let setupScriptName = "Setup.cmd"
    static let statusScriptName = "Status.cmd"
    static let setupVersionFileName = "Setup.version"

    /// Changes whenever the scripts on the disk change, so that disks with older scripts are created again.
    private static let layoutVersion = 8

    static var contentsVersion: String { "\(WindowsDrivers.contentsVersion)/\(layoutVersion)/\(WindowsDrivers.bundledProgramsDigest)" }

    /// Installs the drivers, the SPICE agent that shares the clipboard, the Hypervisaur agent that runs programs for the Mac,
    /// and tasks that tell Hypervisaur when Windows has started and when someone has signed in. Running it in a virtual machine
    /// that was set up without it is how they're installed later.
    ///
    /// The SPICE agent's service starts the agent in each session that's signed in. The Hypervisaur agent is a service of its own,
    /// which starts again if it stops. Both are stopped while they're replaced, and the SPICE agent's licenses and sources are
    /// installed with it. The tasks run as the system account, so that no window appears when they run.
    ///
    /// Fast Startup is turned off, because Hypervisaur replaces this disk while Windows is shut down. With Fast Startup, Windows
    /// resumes with the disk as it was when it shut down, so it doesn't see what's changed, and can write its old view of the
    /// disk over the new one.
    static let setupScript = """
    @echo off
    rem Installs the VirtIO drivers and the clipboard agent for Windows virtual machines in Hypervisaur.

    pnputil /add-driver "%~dp0*.inf" /subdirs /install

    reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f >nul

    set "AgentFolder=%ProgramFiles%\\Hypervisaur\\SPICE Agent"
    if exist "%~dp0\(WindowsDrivers.clipboardAgent.folderName)\\vdservice.exe" (
        net stop vdservice >nul 2>&1
        taskkill /f /im vdagent.exe >nul 2>&1
        mkdir "%AgentFolder%" 2>nul
        copy /y "%~dp0\(WindowsDrivers.clipboardAgent.folderName)\\*.*" "%AgentFolder%" >nul
        "%AgentFolder%\\vdservice.exe" install >nul 2>&1
        sc config vdservice start= auto >nul
        net start vdservice >nul 2>&1
    )

    set "GuestAgentFolder=%ProgramFiles%\\Hypervisaur\\Agent"
    if exist "%~dp0\(WindowsDrivers.guestAgent.folderName)\\HypervisaurAgent.exe" (
        net stop HypervisaurAgent >nul 2>&1
        mkdir "%GuestAgentFolder%" 2>nul
        copy /y "%~dp0\(WindowsDrivers.guestAgent.folderName)\\*.*" "%GuestAgentFolder%" >nul
        sc query HypervisaurAgent >nul 2>&1 || sc create HypervisaurAgent binPath= "\\"%GuestAgentFolder%\\HypervisaurAgent.exe\\"" start= auto DisplayName= "Hypervisaur Agent" >nul
        sc description HypervisaurAgent "Runs programs in this virtual machine for Hypervisaur on the Mac." >nul
        sc failure HypervisaurAgent reset= 86400 actions= restart/5000/restart/5000/restart/5000 >nul
        net start HypervisaurAgent >nul 2>&1
    )

    set "StatusScript=%ProgramData%\\Hypervisaur\\\(statusScriptName)"
    mkdir "%ProgramData%\\Hypervisaur" 2>nul
    copy /y "%~dp0\(statusScriptName)" "%StatusScript%" >nul
    copy /y "%~dp0\(setupVersionFileName)" "%ProgramData%\\Hypervisaur\\\(setupVersionFileName)" >nul
    schtasks /create /f /tn "Hypervisaur\\Started" /sc onstart /ru SYSTEM /tr "%StatusScript% startup" >nul
    schtasks /create /f /tn "Hypervisaur\\Signed In" /sc onlogon /ru SYSTEM /tr "%StatusScript%" >nul

    exit /b 0

    """.windowsLineEndings

    /// Writes to the status port when Windows starts, and once someone has signed in and their desktop has started.
    /// See ``WindowsGuestStatus``.
    ///
    /// When Windows starts, it first runs the setup script on the drivers disk if it's a different version from the one
    /// that was last run. The drivers disk is a USB drive, which Windows may not have mounted yet, so it's waited for for up to
    /// 30 seconds. The setup script replaces this script while it runs, which is safe because Windows reads the whole of
    /// a parenthesized block before running it, and nothing after the block is read again.
    ///
    /// Windows Setup signs in to a temporary account to finish setting up, so the script also waits for Setup to have
    /// finished, and ignores that account's desktop. `timeout` doesn't work without a console, so `ping` waits between checks.
    static let statusScript = """
    @echo off
    rem Tells Hypervisaur when Windows has started, and when someone has signed in.

    if /i "%~1"=="startup" (
        set "DriversChecked="
        for /l %%i in (1,1,15) do if not defined DriversChecked (
            for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if not defined DriversChecked if exist "%%d:\\\(driversFolderName)\\\(setupVersionFileName)" (
                set "DriversChecked=1"
                fc /b "%%d:\\\(driversFolderName)\\\(setupVersionFileName)" "%ProgramData%\\Hypervisaur\\\(setupVersionFileName)" >nul 2>&1 || call "%%d:\\\(driversFolderName)\\\(setupScriptName)"
            )
            if not defined DriversChecked ping -n 3 127.0.0.1 >nul
        )
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
            for program in WindowsDrivers.bundledPrograms {
                try WindowsDrivers.copy(program, from: WindowsDrivers.bundledURL(of: program), into: destinationURL)
            }
            try Data(setupScript.utf8).write(to: destinationURL.appending(path: setupScriptName))
            try Data(statusScript.utf8).write(to: destinationURL.appending(path: statusScriptName))
            try Data(contentsVersion.utf8).write(to: destinationURL.appending(path: setupVersionFileName))
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
