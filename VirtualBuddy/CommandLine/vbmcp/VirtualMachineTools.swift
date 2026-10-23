import AppKit
import VirtualCore

/// The tools that `vbmcp` offers for creating and running virtual machines.
///
/// Virtual machines are created in the library by this process, then started in the app, the same way as from the library window.
/// Starting and stopping go through the app's URL scheme, so the app asks the user once whether to allow it.
enum VirtualMachineTools {
    static var all: [MCPTool] {
        [listVirtualMachines, getStatus, getWindowsRequirements, installWindowsRequirements, createWindowsVM, waitForWindowsVM, startVM, stopVM]
    }

    static let instructions = """
    Creates and runs Windows 11 virtual machines in Hypervisaur on this Mac. create_windows_vm installs Windows without \
    any interaction and signs in to a local account, which takes about 10 minutes; call wait_for_windows_vm afterwards \
    to wait until the desktop is ready. The first time Hypervisaur is asked to start a virtual machine, it asks the user \
    to allow it.
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
        description: "Asks a running virtual machine to shut down, as if its power button was pressed.",
        inputSchema: schema(["name": property("string", "The name of the virtual machine.")], required: ["name"]),
        run: { arguments, _ in
            let model = try Library.machine(named: try arguments.requiredString("name"))
            try await App.open("stop", name: model.name)
            return "Asked \(model.name) to shut down."
        }
    )

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

    private static let stoppedGracePeriod = Duration.seconds(30)

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
        guard url.isReadableDirectory else { return [] }

        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == VBVirtualMachine.bundleExtension }
            .compactMap { try? VBVirtualMachine(bundleURL: $0, createIfNeeded: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func machine(named name: String) throws -> VBVirtualMachine {
        guard let model = try machines().first(where: { $0.name == name }) else {
            throw Failure("There’s no virtual machine named “\(name)” in the library at \(url.path).")
        }
        return model
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
    static func open(_ action: String, name: String) async throws {
        var components = URLComponents()
        components.scheme = "hypervisaur"
        components.host = action
        components.queryItems = [URLQueryItem(name: "name", value: name)]

        guard let url = components.url else {
            throw Failure("Couldn’t make a request for “\(name)”.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        _ = try await NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
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
