import Foundation
import OSLog

/// Switches Windows to the resolution of a display it was started with in place of its own, such as for a full-screen start.
///
/// Windows treats each resolution that the display device offers as a different monitor. A monitor it hasn't seen before
/// starts at its display driver's default, 1024 by 768, rather than at the resolution it's offered, and Windows
/// remembers whatever a monitor was last switched to. So the first time Windows is started at a resolution, it has to be
/// switched to it, and afterwards it starts at it by itself.
///
/// Only the session of the user signed in at the display can change its resolution, and the Hypervisaur agent runs as a
/// service outside it. So the agent registers a scheduled task that runs once in that session, as that user, and
/// switches the resolution, then removes the task. Nobody may have signed in yet when Windows starts, so this keeps trying
/// until somebody has.
@MainActor
final class WindowsDisplayResolution {
    /// How a run of ``command`` ended.
    enum Outcome: Int32 {
        case switched = 0
        case alreadySet = 2
        case nobodySignedIn = 3
        case didNotSwitch = 4
    }

    /// How long to wait between attempts, such as while nobody has signed in.
    static let retryInterval = Duration.seconds(10)
    /// Attempts that fail for any reason other than nobody having signed in, after which trying again is pointless.
    static let maximumFailures = 3

    let width: Int
    let height: Int

    private let logger: Logger
    private var task: Task<Void, Never>?

    init(width: Int, height: Int, guestName: String) {
        self.width = width
        self.height = height
        self.logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "WindowsDisplayResolution(\(guestName))")
    }

    /// Switches the resolution once the agent is running and somebody has signed in.
    /// - Parameter connection: The connection to the agent, while there's one.
    func apply(using connection: @escaping @MainActor () -> GuestAgentConnection?) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(using: connection)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(using connection: @MainActor () -> GuestAgentConnection?) async {
        var failures = 0

        while !Task.isCancelled {
            if let connection = connection(), connection.info != nil {
                do {
                    let result = try await connection.run(Self.command(width: width, height: height), timeout: .seconds(90))

                    switch Outcome(rawValue: result.status) {
                    case .switched:
                        logger.notice("Switched Windows to \(self.width)x\(self.height)")
                        return
                    case .alreadySet:
                        logger.info("Windows is already at \(self.width)x\(self.height)")
                        return
                    case .nobodySignedIn:
                        logger.debug("Waiting for somebody to sign in to switch Windows to \(self.width)x\(self.height)")
                    case .didNotSwitch, nil:
                        failures += 1
                        logger.error("Couldn't switch Windows to \(self.width)x\(self.height), status \(result.status): \(String(decoding: result.errorOutput, as: UTF8.self), privacy: .public)")
                    }
                } catch {
                    /// The agent restarting or going away isn't a reason to give up: it comes back.
                    logger.notice("Couldn't ask Windows to switch its resolution yet: \(error, privacy: .public)")
                }

                guard failures < Self.maximumFailures else {
                    logger.error("Giving up on switching Windows to \(self.width)x\(self.height)")
                    return
                }
            }

            try? await Task.sleep(for: Self.retryInterval)
        }
    }

    /// What the agent runs, as the system, in PowerShell. Its exit status is one of the ``Outcome``s.
    static func command(width: Int, height: Int) -> String {
        """
        $ErrorActionPreference = 'Stop'
        $wanted = '\(width)x\(height)'
        function Get-Resolution {
            $controller = Get-CimInstance Win32_VideoController | Select-Object -First 1
            "$($controller.CurrentHorizontalResolution)x$($controller.CurrentVerticalResolution)"
        }

        if ((Get-Resolution) -eq $wanted) { exit \(Outcome.alreadySet.rawValue) }

        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { exit \(Outcome.nobodySignedIn.rawValue) }

        $switch = @'
        Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        namespace Hypervisaur {
            public static class Display {
                [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
                struct DEVMODE {
                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
                    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
                    public int dmFields;
                    public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
                    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
                    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
                    public int dmDisplayFlags; public int dmDisplayFrequency;
                    public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
                    public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
                }
                [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string deviceName, int modeNumber, ref DEVMODE mode);
                [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE mode, int flags);
                // Switches the display and saves the resolution, so that Windows starts at it next time. Returns 0 when it switched.
                public static int Switch(int width, int height) {
                    var mode = new DEVMODE();
                    mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                    if (!EnumDisplaySettings(null, -1, ref mode)) { return -1; }
                    mode.dmPelsWidth = width;
                    mode.dmPelsHeight = height;
                    mode.dmFields = 0x80000 | 0x100000;
                    return ChangeDisplaySettings(ref mode, 1);
                }
            }
        }
        "@
        exit [Hypervisaur.Display]::Switch(\(width), \(height))
        '@

        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($switch))
        $name = 'Hypervisaur Display Resolution'
        # conhost runs PowerShell without showing a window over the user's desktop.
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null

        try {
            Start-ScheduledTask -TaskName $name
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and (Get-Resolution) -ne $wanted) { Start-Sleep -Milliseconds 500 }
        } finally {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }

        if ((Get-Resolution) -eq $wanted) { exit \(Outcome.switched.rawValue) }
        exit \(Outcome.didNotSwitch.rawValue)
        """
    }
}
