import AppKit
import UniformTypeIdentifiers
import VirtualCore

/// The tools that `vbmcp` offers for creating and running virtual machines.
///
/// Virtual machines are created in the library by this process, then started in the app, the same way as from the library window.
/// Starting and stopping go through the app's URL scheme, so the app asks the user once whether to allow it.
enum VirtualMachineTools {
    static var all: [MCPTool] {
        [listVirtualMachines, getStatus, getWindowsRequirements, installWindowsRequirements, createWindowsVM, waitForWindowsVM, startVM, stopVM, takeScreenshot, cloneVM, runCommand, getGuestLogs]
    }

    static let instructions = """
    Creates and runs Windows 11 virtual machines in Hypervisaur on this Mac. create_windows_vm installs Windows without \
    any interaction and signs in to a local account, which takes about 10 minutes; call wait_for_windows_vm afterwards \
    to wait until the desktop is ready. take_screenshot shows what's on a running virtual machine's display, and clone_vm \
    makes a copy of a virtual machine that can run alongside it. run_command runs commands in a running virtual machine, \
    in PowerShell on Windows, and get_guest_logs shows its recent log entries. The first time Hypervisaur is asked to \
    start or stop something, it asks the user to allow it.
    """

    // MARK: - Tools

    private static let listVirtualMachines = MCPTool(
        name: "list_virtual_machines",
        title: "List Virtual Machines",
        description: "Lists the virtual machines in the Hypervisaur library, with the status of Windows virtual machines.",
        inputSchema: ["type": "object", "properties": [:]],
        run: { _, _ in
            let machines = try Library.machines()
            guard !machines.isEmpty else { return "The library at \(Library.url.path) has no virtual machines." }

            return machines.map { model in
                switch model.configuration.systemType {
                case .windows: "- \(model.name) (Windows): \(WindowsGuestStatus(for: model).summary)"
                case .mac: "- \(model.name) (macOS)"
                case .linux: "- \(model.name) (Linux)"
                }
            }.joined(separator: "\n")
        }
    )

    private static let getStatus = MCPTool(
        name: "get_windows_vm_status",
        title: "Get Windows Virtual Machine Status",
        description: "Tells whether a Windows virtual machine is stopped, installing Windows, starting up, or signed in at the desktop.",
        inputSchema: schema(["name": property("string", "The name of the virtual machine.")], required: ["name"]),
        run: { arguments, _ in
            let model = try Library.windowsMachine(named: try arguments.requiredString("name"))
            return "\(model.name): \(WindowsGuestStatus(for: model).summary)"
        }
    )

    private static let getWindowsRequirements = MCPTool(
        name: "get_windows_requirements",
        title: "Get Windows Requirements",
        description: "Checks whether the software that Windows virtual machines need is installed on this Mac: Homebrew, QEMU, swtpm, wimlib and the Windows drivers.",
        inputSchema: ["type": "object", "properties": [:]],
        run: { _, _ in
            await Requirements.summary()
        }
    )

    private static let installWindowsRequirements = MCPTool(
        name: "install_windows_requirements",
        title: "Install Windows Requirements",
        description: "Installs the missing software that Windows virtual machines need, using Homebrew, and downloads the Windows drivers. Homebrew itself must already be installed.",
        inputSchema: ["type": "object", "properties": [:]],
        run: { _, progress in
            try await Requirements.installMissing(progress: progress)
            return await Requirements.summary()
        }
    )

    private static let createWindowsVM = MCPTool(
        name: "create_windows_vm",
        title: "Create Windows Virtual Machine",
        description: """
        Creates a Windows 11 virtual machine and starts installing Windows in it, without any interaction. Windows Setup \
        creates a local administrator account and signs in to it. Returns once the virtual machine has started; installing \
        Windows takes about 10 minutes more, so call wait_for_windows_vm to wait until it's signed in at the desktop.
        """,
        inputSchema: schema([
            "username": property("string", "The name of the local Windows account to create and sign in to, such as \"neiljohn\". Up to 20 characters."),
            "password": property("string", "The account's password. Without one, the account has no password and Windows signs in to it every time it starts."),
            "name": property("string", "The name of the virtual machine in Hypervisaur. Defaults to \"Windows 11\", numbered if that's taken."),
            "disk_size_gb": property("integer", "The size of the virtual machine's disk in gigabytes. At least 64; defaults to 80. The disk only uses as much space as it contains."),
            "memory_gb": property("integer", "The memory for the virtual machine in gigabytes. At least 4; defaults to \(VBMacDevice.defaultWindows.memorySize / .storageGigabyte)."),
            "cpu_count": property("integer", "The number of processor cores. Defaults to \(VBMacDevice.defaultWindows.cpuCount)."),
            "installer_path": property("string", "The path of the Windows 11 for ARM disc image (ISO). Defaults to the installer used for the most recent Windows virtual machine, or the only Windows ARM ISO in Downloads."),
            "start": property("boolean", "Whether to start the virtual machine and begin installing Windows. Defaults to true."),
        ], required: ["username"]),
        run: { arguments, progress in
            try await createWindowsVirtualMachine(arguments: arguments, progress: progress)
        }
    )

    private static let waitForWindowsVM = MCPTool(
        name: "wait_for_windows_vm",
        title: "Wait for Windows Virtual Machine",
        description: "Waits until someone has signed in to Windows in the virtual machine and the desktop has started, reporting progress while Windows installs or starts up.",
        inputSchema: schema([
            "name": property("string", "The name of the virtual machine."),
            "timeout_minutes": property("integer", "How long to wait before giving up. Defaults to 30."),
        ], required: ["name"]),
        run: { arguments, progress in
            let name = try arguments.requiredString("name")
            let timeout = Duration.seconds(60 * (arguments.integer("timeout_minutes") ?? 30))
            return try await waitUntilSignedIn(name: name, timeout: timeout, progress: progress)
        }
    )

    private static let startVM = MCPTool(
        name: "start_vm",
        title: "Start Virtual Machine",
        description: "Starts a virtual machine in Hypervisaur, opening its window.",
        inputSchema: schema(["name": property("string", "The name of the virtual machine.")], required: ["name"]),
        run: { arguments, progress in
            let model = try Library.machine(named: try arguments.requiredString("name"))
            return try await start(model, progress: progress)
        }
    )

    private static let stopVM = MCPTool(
        name: "stop_vm",
        title: "Stop Virtual Machine",
        description: "Asks a running virtual machine to shut down, as if its power button was pressed. For Windows, waits until it has shut down.",
        inputSchema: schema(["name": property("string", "The name of the virtual machine.")], required: ["name"]),
        run: { arguments, progress in
            let model = try Library.machine(named: try arguments.requiredString("name"))
            return try await stop(model, progress: progress)
        }
    )

    private static let takeScreenshot = MCPTool(
        name: "take_screenshot",
        title: "Take Screenshot",
        description: "Takes a screenshot of a running virtual machine's display and returns it as an image.",
        inputSchema: schema([
            "name": property("string", "The name of the virtual machine."),
            "max_size": property("integer", "The most pixels the image may have on its longer side; larger screenshots are scaled down. Defaults to \(Screenshots.defaultMaximumSize)."),
            "save_path": property("string", "A path to also save the screenshot to as a PNG file, at its full size."),
        ], required: ["name"]),
        result: { arguments, progress in
            let model = try Library.machine(named: try arguments.requiredString("name"))
            return try await Screenshots.take(
                of: model,
                maximumSize: arguments.integer("max_size") ?? Screenshots.defaultMaximumSize,
                savingTo: arguments.string("save_path").map { URL(filePath: ($0 as NSString).expandingTildeInPath) },
                progress: progress
            )
        }
    )

    private static let cloneVM = MCPTool(
        name: "clone_vm",
        title: "Clone Virtual Machine",
        description: """
        Makes a copy of a virtual machine that can run at the same time as the original, with its own network address \
        and, for macOS, its own serial number. The copy shares disk space with the original until either of them changes, \
        so it's quick to make and only takes up the space of what's different. The virtual machine must be shut down, \
        without a saved session.
        """,
        inputSchema: schema([
            "name": property("string", "The name of the virtual machine to clone."),
            "clone_name": property("string", "The name of the copy. Defaults to \"Clone of\" the original's name, numbered if that's taken."),
        ], required: ["name"]),
        run: { arguments, progress in
            let model = try Library.machine(named: try arguments.requiredString("name"))
            return try await clone(model, as: arguments.string("clone_name"), progress: progress)
        }
    )

    private static let runCommand = MCPTool(
        name: "run_command",
        title: "Run Command",
        description: """
        Runs a command in a running virtual machine and returns its output and exit status. On Windows, commands run in \
        PowerShell as the system account, so they can change anything. On Linux they run with /bin/sh as root, and on macOS \
        with the user's login shell, as the user who's signed in. Commands can't be interactive: they get no input and have \
        no terminal. The virtual machine needs the Hypervisaur agent: Windows installs it from the DRIVERS disk when it starts, \
        Linux installs it from the HYPERVISAUR disc, and on macOS it's part of the guest app.
        """,
        inputSchema: schema([
            "name": property("string", "The name of the virtual machine."),
            "command": property("string", "The command to run, which can have several lines."),
            "timeout_seconds": property("integer", "How long the command may run before it's stopped. Defaults to 120."),
        ], required: ["name", "command"]),
        run: { arguments, _ in
            let model = try Library.machine(named: try arguments.requiredString("name"))
            let timeout = Duration.seconds(max(1, arguments.integer("timeout_seconds") ?? 120))
            let result = try await GuestAgentClient.run(
                try arguments.requiredString("command"),
                inVirtualMachineAt: model.bundleURL,
                name: model.name,
                timeout: timeout,
                outputLimit: commandOutputLimit
            )
            return describe(result, timeout: timeout)
        }
    )

    private static let getGuestLogs = MCPTool(
        name: "get_guest_logs",
        title: "Get Guest Logs",
        description: """
        Returns the most recent entries from a running virtual machine's logs, oldest first: the System and Application \
        event logs on Windows, the unified log on macOS, and the journal on Linux. Needs the Hypervisaur agent, like run_command.
        """,
        inputSchema: schema([
            "name": property("string", "The name of the virtual machine."),
            "count": property("integer", "How many entries to return. Defaults to 100, at most 1000."),
        ], required: ["name"]),
        run: { arguments, _ in
            let model = try Library.machine(named: try arguments.requiredString("name"))
            let count = min(max(1, arguments.integer("count") ?? 100), 1000)
            let result = try await GuestAgentClient.run(
                GuestLogs.recentCommand(for: model.configuration.systemType, count: count),
                inVirtualMachineAt: model.bundleURL,
                name: model.name,
                timeout: .seconds(60),
                outputLimit: commandOutputLimit
            )
            let entries = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return entries.isEmpty ? "There are no log entries." : entries
        }
    )

    /// Output is limited so that the reply stays a reasonable size for the agent that asked.
    private static let commandOutputLimit = 200_000

    private static func describe(_ result: GuestAgentCommandResult, timeout: Duration) -> String {
        var sections = [result.timedOut ? "The command was stopped after \(timeout.components.seconds) seconds." : "Exit status: \(result.status)"]

        let output = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        let errorOutput = String(decoding: result.errorOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
        if !output.isEmpty { sections.append("Output:\n\(output)") }
        if !errorOutput.isEmpty { sections.append("Errors:\n\(errorOutput)") }
        if output.isEmpty && errorOutput.isEmpty { sections.append("There was no output.") }
        if result.isTruncated { sections.append("Some of the output was left out because there was more than \(commandOutputLimit) bytes.") }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Creating

    private static func createWindowsVirtualMachine(arguments: JSONValue, progress: @escaping MCPTool.ProgressHandler) async throws -> String {
        let username = try arguments.requiredString("username")
        try WindowsUnattendedSetup.validateAccountName(username)

        let name = arguments.string("name") ?? Library.availableName(base: "Windows 11")
        let installerURL = try arguments.string("installer_path").map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? Library.defaultWindowsInstallerURL()
        let defaults = VBMacDevice.defaultWindows

        let request = WindowsVirtualMachineProvisioner.Request(
            name: name,
            installerURL: installerURL,
            setup: WindowsUnattendedSetup(accountName: username, password: arguments["password"]?.stringValue),
            diskSize: UInt64(arguments.integer("disk_size_gb") ?? Int(VBManagedDiskImage.defaultWindowsBootDiskImageSize / .storageGigabyte)) * .storageGigabyte,
            memorySize: arguments.integer("memory_gb").map { UInt64($0) * .storageGigabyte } ?? defaults.memorySize,
            cpuCount: arguments.integer("cpu_count") ?? defaults.cpuCount
        )

        if await Requirements.onlyDriversAreMissing() {
            await progress("Downloading the Windows drivers", nil)
            try await WindowsDrivers.install(onOutput: { _ in })
        }

        await progress("Preparing the Windows installer from \(installerURL.lastPathComponent)", 0)

        let model = try await WindowsVirtualMachineProvisioner.create(request, in: Library.url) { installProgress in
            Task { await progress(installProgress.description, installProgress.fractionCompleted) }
        }

        let account = request.setup?.password == nil ? "\(username), without a password" : username
        let created = "Created \(model.name) with \(request.diskSize / .storageGigabyte) GB disk, \(request.memorySize / .storageGigabyte) GB memory and \(request.cpuCount) cores, from \(installerURL.path). Windows will sign in to the local account \(account)."

        guard arguments.bool("start") ?? true else {
            return created + " It hasn't been started; call start_vm to install Windows."
        }

        let started = try await start(model, progress: progress)
        return created + "\n" + started + " Installing Windows takes about 10 minutes; call wait_for_windows_vm to wait until it's signed in at the desktop."
    }

    // MARK: - Running

    /// How long to wait for the app to start the virtual machine, which includes the time the user may take to allow it.
    private static let startTimeout = Duration.seconds(120)

    private static func start(_ model: VBVirtualMachine, progress: @escaping MCPTool.ProgressHandler) async throws -> String {
        guard model.configuration.systemType != .windows || WindowsGuestStatus(for: model) == .stopped else {
            return "\(model.name) is already running."
        }

        try await App.open("boot", name: model.name)

        guard model.configuration.systemType == .windows else {
            return "Asked Hypervisaur to start \(model.name)."
        }

        await progress("Waiting for Hypervisaur to start \(model.name)", nil)

        let deadline = ContinuousClock.now + startTimeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            if WindowsGuestStatus(for: model) != .stopped {
                return "Started \(model.name) in Hypervisaur."
            }
        }

        throw Failure("Hypervisaur hasn’t started \(model.name). If Hypervisaur is asking whether to allow it to be controlled, allow it, then call start_vm again.")
    }

    /// Cloning on a volume that isn't APFS copies everything, which takes a while for a large disk.
    private static let cloneTimeout = Duration.seconds(30 * 60)

    private static func clone(_ model: VBVirtualMachine, as cloneName: String?, progress: @escaping MCPTool.ProgressHandler) async throws -> String {
        let replyID = UUID()
        var parameters = ["reply": replyID.uuidString]
        if let cloneName {
            parameters["cloneName"] = cloneName
        }

        try await App.open("clone", name: model.name, parameters: parameters)
        await progress("Waiting for Hypervisaur to clone \(model.name)", nil)

        let reply = try await AutomationReply.wait(
            for: replyID,
            timeout: cloneTimeout,
            timeoutMessage: "Hypervisaur hasn’t cloned \(model.name). If Hypervisaur is asking whether to allow it to be controlled, allow it, then call clone_vm again."
        )
        return reply.message ?? "Cloned \(model.name)."
    }

    private static let stoppedGracePeriod = Duration.seconds(30)

    /// How long Windows has to shut down, and how often its power button is pressed again meanwhile. The first press
    /// only wakes Windows if its display has gone to sleep.
    private static let stopTimeout = Duration.seconds(180)
    private static let powerButtonInterval = Duration.seconds(30)

    private static func stop(_ model: VBVirtualMachine, progress: @escaping MCPTool.ProgressHandler) async throws -> String {
        guard model.configuration.systemType == .windows else {
            try await App.open("stop", name: model.name)
            return "Asked \(model.name) to shut down."
        }

        guard WindowsGuestStatus(for: model) != .stopped else {
            return "\(model.name) isn’t running."
        }

        let deadline = ContinuousClock.now + stopTimeout
        while ContinuousClock.now < deadline {
            try await App.open("stop", name: model.name)
            await progress("Waiting for \(model.name) to shut down", nil)

            let nextPress = ContinuousClock.now + powerButtonInterval
            while ContinuousClock.now < nextPress {
                try await Task.sleep(for: .seconds(1))
                if WindowsGuestStatus(for: model) == .stopped {
                    return "\(model.name) has shut down."
                }
            }
        }

        throw Failure("\(model.name) didn’t shut down within \(stopTimeout.components.seconds / 60) minutes. Windows may be waiting for something, such as unsaved work.")
    }

    private static func waitUntilSignedIn(name: String, timeout: Duration, progress: @escaping MCPTool.ProgressHandler) async throws -> String {
        let model = try Library.windowsMachine(named: name)
        let start = ContinuousClock.now
        var lastStatus: WindowsGuestStatus?
        var lastReport = start
        var stoppedSince: ContinuousClock.Instant?

        while true {
            let status = WindowsGuestStatus(for: model)
            let elapsed = ContinuousClock.now - start

            if status != .stopped {
                stoppedSince = nil
            }

            switch status {
            case .signedIn:
                return "\(model.name) is signed in at the Windows desktop."
            case .stopped:
                /// The virtual machine stops for a moment when it restarts at the end of an unattended installation.
                let since = stoppedSince ?? .now
                stoppedSince = since
                if ContinuousClock.now - since >= stoppedGracePeriod {
                    throw Failure("\(model.name) isn’t running. Call start_vm to start it.")
                }
            case .installing, .starting:
                /// Reports regularly even without a change, so that clients know the call is still making progress.
                if status != lastStatus || ContinuousClock.now - lastReport >= .seconds(30) {
                    await progress("\(status.summary) (\(Int(elapsed.components.seconds / 60)) min)", nil)
                    lastStatus = status
                    lastReport = .now
                }
            }

            guard elapsed < timeout else {
                throw Failure("\(model.name) still wasn’t signed in after \(timeout.components.seconds / 60) minutes. It’s \(status.summary.lowercased()).")
            }

            try await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: - Schemas

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    private static func property(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }
}

// MARK: - Library

private enum Library {
    static var url: URL { VBSettings.current.libraryURL }

    static func machines() throws -> [VBVirtualMachine] {
        try VBVirtualMachine.libraryMachines(in: url)
    }

    static func machine(named name: String) throws -> VBVirtualMachine {
        try VBVirtualMachine.libraryMachine(named: name, in: url)
    }

    static func windowsMachine(named name: String) throws -> VBVirtualMachine {
        let model = try machine(named: name)
        guard model.configuration.systemType == .windows else {
            throw Failure("“\(name)” isn’t a Windows virtual machine.")
        }
        return model
    }

    static func availableName(base: String) -> String {
        let existing = Set((try? machines())?.map(\.name) ?? [])
        guard existing.contains(base) else { return base }

        var number = 2
        while existing.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }

    /// The installer that the most recent Windows virtual machine was created from, or the only Windows ARM disc image in Downloads.
    static func defaultWindowsInstallerURL() throws -> URL {
        let recentInstaller = try machines()
            .filter { $0.configuration.systemType == .windows }
            .compactMap { model -> (URL, Date)? in
                guard let installer = model.metadata.installImageURL, FileManager.default.isReadableFile(atPath: installer.path) else { return nil }
                let created = (try? model.bundleURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (installer, created)
            }
            .max { $0.1 < $1.1 }?
            .0

        if let recentInstaller { return recentInstaller }

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let candidates = ((try? FileManager.default.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return url.pathExtension.lowercased() == "iso" && name.contains("win") && (name.contains("arm64") || name.contains("aarch64"))
            }

        switch candidates.count {
        case 1:
            return candidates[0]
        case 0:
            throw Failure("Couldn’t find a Windows installer. Download the Windows 11 ARM64 disc image from Microsoft and pass its path as installer_path.")
        default:
            throw Failure("There are several Windows installers in Downloads. Pass one of them as installer_path: \(candidates.map(\.path).joined(separator: ", ")).")
        }
    }
}

// MARK: - Requirements

private enum Requirements {
    @MainActor
    static func summary() async -> String {
        let dependencies = WindowsHostDependencies.shared
        await dependencies.refresh()

        var lines = WindowsHostDependency.allCases.map { dependency in
            switch dependencies.status(for: dependency) {
            case .installed(let version): "- \(dependency.name): installed\(version.map { " (\($0))" } ?? "")"
            case .missing, .unknown: "- \(dependency.name): missing"
            case .installing: "- \(dependency.name): installing"
            case .failed(let message): "- \(dependency.name): failed to install. \(message)"
            }
        }

        if dependencies.status(for: .homebrew) == .missing {
            lines.append("Homebrew must be installed by the user in Terminal with: \(Homebrew.installCommand)")
        } else if !dependencies.allInstalled {
            lines.append("Call install_windows_requirements to install what's missing.")
        }

        return lines.joined(separator: "\n")
    }

    @MainActor
    static func onlyDriversAreMissing() async -> Bool {
        let dependencies = WindowsHostDependencies.shared
        await dependencies.refresh()

        return !dependencies.status(for: .windowsDrivers).isInstalled
            && WindowsHostDependency.allCases.allSatisfy { $0 == .windowsDrivers || dependencies.status(for: $0).isInstalled }
    }

    @MainActor
    static func installMissing(progress: @escaping MCPTool.ProgressHandler) async throws {
        let dependencies = WindowsHostDependencies.shared
        await dependencies.refresh()

        guard let brew = Homebrew.current else {
            throw Failure("Homebrew isn’t installed. The user needs to install it in Terminal with: \(Homebrew.installCommand)")
        }

        let formulae = WindowsHostDependency.allCases.compactMap { dependency in
            dependencies.status(for: dependency).isInstalled ? nil : dependency.formula
        }

        if !formulae.isEmpty {
            await progress("Installing \(formulae.joined(separator: ", ")) with Homebrew", nil)
            try await brew.install(formulae) { line in
                Task { await progress(line, nil) }
            }
        }

        if !WindowsDrivers.isInstalled {
            await progress("Downloading the Windows drivers", 0)
            try await WindowsDrivers.install(onOutput: { _ in }) { fraction in
                Task { await progress("Downloading the Windows drivers", fraction) }
            }
        }
    }
}

// MARK: - App

private enum App {
    /// Sends a request to this copy of the app, which launches it if needed. The app comes to the front, since it may need
    /// to ask the user whether to allow the request.
    @MainActor
    static func open(_ action: String, name: String, parameters: [String: String] = [:]) async throws {
        var components = URLComponents()
        components.scheme = "hypervisaur"
        components.host = action
        components.queryItems = [URLQueryItem(name: "name", value: name)] + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw Failure("Couldn’t make a request for “\(name)”.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        _ = try await NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
    }
}

// MARK: - Screenshots

private enum Screenshots {
    /// Claude looks at images up to this size without scaling them down.
    static let defaultMaximumSize = 1568

    /// How long to wait for the app, which includes the time the user may take to allow it, and to allow it to record the screen.
    static let timeout = Duration.seconds(120)

    static func take(of model: VBVirtualMachine, maximumSize: Int, savingTo saveURL: URL?, progress: @escaping MCPTool.ProgressHandler) async throws -> MCPToolResult {
        let replyID = UUID()
        let attachmentURL = AutomationReply.attachmentURL(for: replyID, pathExtension: "png")
        defer { try? FileManager.default.removeItem(at: attachmentURL) }

        try await App.open("screenshot", name: model.name, parameters: ["reply": replyID.uuidString])
        await progress("Waiting for Hypervisaur to take a screenshot of \(model.name)", nil)

        let reply = try await AutomationReply.wait(
            for: replyID,
            timeout: timeout,
            timeoutMessage: "Hypervisaur hasn’t taken a screenshot of \(model.name). If Hypervisaur is asking whether to allow it to be controlled or to record the screen, allow it, then call take_screenshot again."
        )

        var text = reply.message ?? "Took a screenshot of \(model.name)."

        if let saveURL {
            try? FileManager.default.removeItem(at: saveURL)
            try FileManager.default.copyItem(at: attachmentURL, to: saveURL)
            text += " Saved it to \(saveURL.path)."
        }

        let data = try scaledPNG(at: attachmentURL, maximumSize: max(maximumSize, 64))
        return MCPToolResult(text: text, image: .init(data: data, mimeType: "image/png"))
    }

    /// The image as a PNG that's no larger than the maximum size on its longer side.
    private static func scaledPNG(at url: URL, maximumSize: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw Failure("The screenshot couldn’t be read.")
        }

        guard max(width, height) > maximumSize else {
            return try Data(contentsOf: url)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure("The screenshot couldn’t be scaled down.")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("The screenshot couldn’t be compressed.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure("The screenshot couldn’t be compressed.")
        }
        return data as Data
    }
}

// MARK: - Helpers

private extension WindowsGuestStatus {
    var summary: String {
        switch self {
        case .stopped: "Stopped"
        case .installing: "Installing Windows"
        case .starting: "Starting up"
        case .signedIn: "Signed in at the desktop"
        }
    }
}

private extension JSONValue {
    func string(_ key: String) -> String? {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw Failure("The \(key) argument is required.") }
        return value
    }

    func integer(_ key: String) -> Int? {
        guard let value = self[key]?.numberValue, value.rounded() == value else { return nil }
        return Int(value)
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }
}
