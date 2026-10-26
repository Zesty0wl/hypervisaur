import Foundation
import Combine
import CoreGraphics
import OSLog

/// A virtual machine that runs in a QEMU process, used for guests that Virtualization can't run.
@MainActor
public final class QEMUVirtualMachine: ObservableObject {
    public enum State: Equatable {
        case stopped
        case starting
        case running
        case paused
        case stopping
    }

    @Published public private(set) var state = State.stopped

    /// The most recent frame from the guest's display.
    public private(set) var latestFrame: CGImage?

    private var frameObservers = [UUID: (CGImage) -> Void]()

    /// Called once when the virtual machine stops, with an error if it didn't stop because the guest shut down or was told to stop.
    var onStop: ((Error?) -> Void)?

    private let model: VBVirtualMachine
    private var installDiskURL: URL?
    private var driversDiskURL: URL?
    private var displayAdapter: QEMULaunchConfiguration.DisplayAdapter
    private let logger: Logger

    private var qemuProcess: Process?
    private var swtpmProcess: Process?
    private var monitor: QMPClient?
    private var display: VNCClient?
    private var clipboardSync: QEMUClipboardSync?
    private var guestAgent: GuestAgentConnection?
    var guestAgentConnection: GuestAgentConnection? { guestAgent }
    let guestAgentInfo = GuestAgentInfoRelay()
    private var guestAgentServer: GuestAgentServer?
    private var runtimeDirectoryURL: URL?
    private var isStopExpected = false
    private var didReportStop = false
    private var isRestarting = false

    /// The machine type QEMU was started with, which stays pinned to a saved session's once it has been restored.
    private var machineType = QEMULaunchConfiguration.defaultMachineType
    /// Whether the sound device is unplugged, because the state was saved or restored. It's plugged in again when the guest resumes.
    private var isSoundDeviceUnplugged = false

    /// What's needed to start the virtual machine from a saved session instead of booting it.
    struct Restoration {
        var stateFileURL: URL
        var machineType: String
    }

    /// Windows Setup runs from the installer, which is only attached until Windows has been installed.
    var isInstallerAttached: Bool { installDiskURL != nil }

    init(model: VBVirtualMachine, installDiskURL: URL?, driversDiskURL: URL?, displayAdapter: QEMULaunchConfiguration.DisplayAdapter) {
        self.model = model
        self.installDiskURL = installDiskURL
        self.driversDiskURL = driversDiskURL
        self.displayAdapter = displayAdapter
        self.logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "QEMUVirtualMachine(\(model.name))")
    }

    // MARK: - Display

    /// Registers a closure that's called on the main queue with each new frame. Returns a token for ``removeFrameObserver(_:)``.
    public func addFrameObserver(_ observer: @escaping (CGImage) -> Void) -> UUID {
        let token = UUID()
        frameObservers[token] = observer
        if let latestFrame { observer(latestFrame) }
        return token
    }

    public func removeFrameObserver(_ token: UUID) {
        frameObservers[token] = nil
    }

    public func sendKey(_ keyNumber: UInt32, isDown: Bool) {
        guard state == .running else { return }
        display?.sendKey(keyNumber, isDown: isDown)
    }

    public func sendPointer(x: Int, y: Int, buttons: VNCClient.PointerButtons) {
        guard state == .running else { return }
        display?.sendPointer(x: x, y: y, buttons: buttons)
    }

    /// Shares the Mac's clipboard with the guest again, such as when the virtual machine's window becomes active,
    /// unless something has been copied in the guest since it was last shared.
    public func offerClipboardToGuest() {
        clipboardSync?.offerHostText()
    }

    // MARK: - Lifecycle

    /// Boots the virtual machine, or starts it from a saved session's state and leaves it paused.
    func start(restoring restoration: Restoration? = nil) async throws {
        guard state == .stopped else { return }

        state = .starting
        isStopExpected = false
        didReportStop = false

        do {
            try await launch(restoring: restoration)
            state = restoration == nil ? .running : .paused
        } catch {
            logger.error("Failed to start: \(error, privacy: .public)")
            await tearDown()
            state = .stopped
            throw error
        }
    }

    func pause() async throws {
        guard state == .running, let monitor else { return }
        try await monitor.execute("stop")
        state = .paused
    }

    func resume() async throws {
        guard state == .paused, let monitor else { return }
        try await monitor.execute("cont")
        state = .running

        if isSoundDeviceUnplugged {
            do {
                try await monitor.execute("device_add", arguments: QEMULaunchConfiguration.soundDeviceProperties)
                isSoundDeviceUnplugged = false
            } catch {
                logger.error("Couldn't plug the sound device in again: \(error, privacy: .public)")
            }
        }
    }

    /// Presses the virtual machine's power button so that the guest can shut down.
    func requestStop() async throws {
        guard state == .running || state == .paused, let monitor else { return }

        if state == .paused {
            try await resume()
        }

        try await monitor.execute("system_powerdown")
    }

    struct Devices {
        var installDiskURL: URL?
        var driversDiskURL: URL?
        var displayAdapter: QEMULaunchConfiguration.DisplayAdapter
    }

    /// How long the guest has to shut down for a restart.
    private static let restartShutdownTimeout = Duration.seconds(300)

    /// Shuts the guest down, then starts it again with different devices. The same instance carries on running,
    /// so whatever shows the virtual machine keeps showing it.
    ///
    /// - Parameter prepareDevices: Called once the guest has shut down, so it can change the disks that were attached.
    func restart(prepareDevices: () async throws -> Devices) async throws {
        guard state == .running, let monitor, let process = qemuProcess else { return }

        isRestarting = true
        defer { isRestarting = false }

        /// Windows may only wake its display when the power button is first pressed, so it's pressed again until it shuts down.
        let deadline = ContinuousClock.now + Self.restartShutdownTimeout
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                throw Failure("The guest didn’t shut down to restart.")
            }

            _ = try? await monitor.execute("system_powerdown")

            let nextPress = ContinuousClock.now + .seconds(30)
            while process.isRunning, ContinuousClock.now < nextPress {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        await tearDown()

        do {
            let devices = try await prepareDevices()
            installDiskURL = devices.installDiskURL
            driversDiskURL = devices.driversDiskURL
            displayAdapter = devices.displayAdapter

            try await launch()
            /// The guest's shutdown was expected, but stopping from now on isn't.
            isStopExpected = false
        } catch {
            logger.error("Failed to restart: \(error, privacy: .public)")
            await tearDown()
            reportStop(error: error)
            throw error
        }
    }

    /// Stops the virtual machine immediately, without giving the guest a chance to shut down.
    func forceStop() async {
        guard state != .stopped else { return }

        isStopExpected = true
        state = .stopping

        if let monitor {
            _ = try? await monitor.execute("quit")
        }

        await waitForQEMUExit(timeout: .seconds(5))

        await tearDown()
        reportStop(error: nil)
    }

    private func launch(restoring restoration: Restoration? = nil) async throws {
        let toolchain = try QEMUToolchain.current()

        machineType = restoration?.machineType ?? QEMULaunchConfiguration.defaultMachineType

        try await prepareBundle(toolchain: toolchain)

        let runtimeDirectoryURL = try Self.makeRuntimeDirectory()
        self.runtimeDirectoryURL = runtimeDirectoryURL

        let paths = QEMULaunchConfiguration.RuntimePaths(
            monitorSocket: runtimeDirectoryURL.appending(path: "qmp.sock"),
            displaySocket: runtimeDirectoryURL.appending(path: "vnc.sock"),
            tpmSocket: runtimeDirectoryURL.appending(path: "tpm.sock"),
            agentSocket: runtimeDirectoryURL.appending(path: "agent.sock")
        )

        var configuration = QEMULaunchConfiguration(
            model: model,
            toolchain: toolchain,
            runtimePaths: paths,
            installDiskURL: installDiskURL,
            driversDiskURL: driversDiskURL,
            displayAdapter: displayAdapter
        )
        configuration.machineType = machineType
        configuration.restoresSavedState = restoration != nil
        let arguments = try configuration.arguments()

        try launchTPM(toolchain: toolchain, socketURL: paths.tpmSocket)
        try await waitForTPMSocket(at: paths.tpmSocket)

        try launchQEMU(toolchain: toolchain, arguments: arguments)

        let monitor = try await connectToQEMU {
            try await QMPClient.connect(path: paths.monitorSocket.path, timeout: .seconds(20)) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        }
        self.monitor = monitor

        let display = try await connectToQEMU {
            try await VNCClient.connect(path: paths.displaySocket.path, timeout: .seconds(10), sharesClipboard: model.configuration.clipboardSharingEnabled)
        }
        display.onFrame = { [weak self] frame in
            self?.deliver(frame)
        }
        display.onDisconnect = { [weak self] error in
            self?.logger.debug("Display disconnected: \(String(describing: error), privacy: .public)")
        }
        self.display = display
        display.start()

        if model.configuration.clipboardSharingEnabled {
            let clipboardSync = QEMUClipboardSync(display: display)
            self.clipboardSync = clipboardSync
            clipboardSync.start()
        }

        try await startGuestAgent(socketURL: paths.agentSocket)

        if let restoration {
            /// The sound device was unplugged before the state was saved, so it has to be unplugged before it's loaded.
            /// It's plugged in again when the guest resumes. See ``QEMULaunchConfiguration/restoresSavedState``.
            if QEMULaunchConfiguration.hasSoundDevice(model) {
                try await unplugSoundDevice(monitor: monitor)
            }
            try await loadState(from: restoration.stateFileURL, monitor: monitor)
        } else {
            isSoundDeviceUnplugged = false
            try await monitor.execute("cont")
        }
    }

    // MARK: - Saved Sessions

    /// QEMU's arguments for booting this virtual machine as it's set up now, without anything that may change between runs.
    /// See ``QEMULaunchConfiguration/comparableArguments()``.
    func comparableArguments() throws -> [String] {
        try QEMULaunchConfiguration(
            model: model,
            toolchain: try QEMUToolchain.current(),
            runtimePaths: .placeholder,
            installDiskURL: installDiskURL,
            driversDiskURL: driversDiskURL,
            displayAdapter: displayAdapter
        ).comparableArguments()
    }

    /// Describes how QEMU was started, which restoring the state saved by ``saveState(to:)`` depends on.
    func savedSessionDescription() async throws -> QEMUSavedSessionDescription {
        let monitor = try requireMonitor()

        let version = try await monitor.execute("query-version") as? [String: Any]
        let numbers = version?["qemu"] as? [String: Any]
        let qemuVersion = ["major", "minor", "micro"].map { "\(numbers?[$0] as? Int ?? 0)" }.joined(separator: ".")

        return QEMUSavedSessionDescription(
            qemuVersion: qemuVersion,
            machineType: try await versionedMachineType(monitor: monitor),
            displayAdapter: displayAdapter,
            hasDriversDisk: driversDiskURL != nil,
            arguments: try comparableArguments()
        )
    }

    /// The machine type is pinned to the version it's an alias of, such as `virt-11.1`, so that a newer QEMU
    /// restores the state with the same hardware.
    private func versionedMachineType(monitor: QMPClient) async throws -> String {
        guard machineType == QEMULaunchConfiguration.defaultMachineType else { return machineType }

        let machines = try await monitor.execute("query-machines") as? [[String: Any]] ?? []

        guard let machine = machines.first(where: { $0["alias"] as? String == machineType }), let name = machine["name"] as? String else {
            throw Failure("QEMU didn’t say which version of the \(machineType) machine it’s running.")
        }

        return name
    }

    /// Saves the paused virtual machine's memory and device state to a file. The disks aren't part of it: they're saved separately.
    ///
    /// The sound device can't be saved, so it's unplugged first, and plugged in again when the guest resumes. Cancelling
    /// stops the save and leaves the virtual machine paused.
    func saveState(to url: URL) async throws {
        guard state == .paused else { throw Failure("The virtual machine has to be paused to save its state.") }

        let monitor = try requireMonitor()
        let runtimeDirectoryURL = try runtimeDirectoryURL.require("QEMU’s runtime directory is unavailable.")

        if QEMULaunchConfiguration.hasSoundDevice(model), !isSoundDeviceUnplugged {
            try await unplugSoundDevice(monitor: monitor)
        }

        let link = try Self.migrationFileLink(to: url, in: runtimeDirectoryURL)
        defer { try? FileManager.default.removeItem(at: link) }

        logger.debug("Saving state to \(url.path, privacy: .public)")

        try await monitor.execute("migrate", arguments: ["uri": "file:\(link.path)"])

        try await waitForMigration(monitor: monitor)
    }

    private func unplugSoundDevice(monitor: QMPClient) async throws {
        try await monitor.execute("device_del", arguments: ["id": QEMULaunchConfiguration.soundDeviceID])
        isSoundDeviceUnplugged = true

        /// USB devices are removed right away, without the guest's help, but the removal is still reported asynchronously.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let devices = try await monitor.execute("qom-list", arguments: ["path": "/machine/peripheral"]) as? [[String: Any]] ?? []
            if !devices.contains(where: { $0["name"] as? String == QEMULaunchConfiguration.soundDeviceID }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }

        throw Failure("The sound device couldn’t be unplugged to save the virtual machine’s state.")
    }

    private func waitForMigration(monitor: QMPClient) async throws {
        while true {
            if Task.isCancelled {
                _ = try? await monitor.execute("migrate_cancel")
                throw CancellationError()
            }

            let info = try await monitor.execute("query-migrate") as? [String: Any]

            switch info?["status"] as? String {
            case "completed":
                return
            case "failed":
                throw Failure("QEMU couldn’t save the virtual machine’s state. \(info?["error-desc"] as? String ?? "")")
            case "cancelled":
                throw CancellationError()
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Loads a saved session's state into QEMU, which was started to wait for it, and leaves the virtual machine paused.
    private func loadState(from url: URL, monitor: QMPClient) async throws {
        let runtimeDirectoryURL = try runtimeDirectoryURL.require("QEMU’s runtime directory is unavailable.")
        let link = try Self.migrationFileLink(to: url, in: runtimeDirectoryURL)
        defer { try? FileManager.default.removeItem(at: link) }

        logger.debug("Loading state from \(url.path, privacy: .public)")

        do {
            try await monitor.execute("migrate-incoming", arguments: ["uri": "file:\(link.path)"])

            /// The state loads in the background, and QEMU exits if it can't be loaded.
            while true {
                let status = (try await monitor.execute("query-status") as? [String: Any])?["status"] as? String

                switch status {
                case "inmigrate":
                    try await Task.sleep(for: .milliseconds(100))
                case "paused":
                    return
                default:
                    throw Failure("QEMU is \(status ?? "in an unknown state") instead of paused after loading the saved state.")
                }
            }
        } catch {
            if let qemuProcess, !qemuProcess.isRunning {
                throw Failure("QEMU couldn’t load the saved state. \(recentLogOutput)")
            }
            throw error
        }
    }

    /// QEMU takes options after a comma in a file's URI, so the file is reached through a link whose path has no commas.
    private static func migrationFileLink(to url: URL, in runtimeDirectoryURL: URL) throws -> URL {
        let link = runtimeDirectoryURL.appending(path: "state")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        return link
    }

    private func requireMonitor() throws -> QMPClient {
        guard let monitor else { throw Failure("The connection to QEMU is unavailable.") }
        return monitor
    }

    /// Connects to the agent's port and lets programs on the Mac reach it. The agent replies once Windows has started it.
    private func startGuestAgent(socketURL: URL) async throws {
        let socket = try await connectToQEMU {
            try await UnixSocketConnection.connect(path: socketURL.path, timeout: .seconds(10))
        }

        let connection = GuestAgentConnection(transport: GuestAgentStreamTransport(name: "GuestAgent", socket: socket), guestName: model.name)

        let name = model.name
        let server = try GuestAgentServer(
            connection: connection,
            socketURL: GuestAgentServer.socketURL(forVirtualMachineAt: model.bundleURL),
            guestName: name
        ) {
            "The Hypervisaur agent isn’t running in “\(name)”. Windows installs it when it starts after Hypervisaur updates its DRIVERS disk. If it still isn’t running once Windows has started, open the DRIVERS disk in Windows, then right-click VirtIODrivers\\Setup.cmd and choose Run as Administrator."
        }

        guestAgent = connection
        guestAgentServer = server
        guestAgentInfo.attach(connection)
        connection.start()
        server.start()
    }

    private func prepareBundle(toolchain: QEMUToolchain) async throws {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: model.windowsEFIVariablesURL.path) {
            try fileManager.copyItem(at: toolchain.firmwareVariablesTemplateURL, to: model.windowsEFIVariablesURL)
        }

        try fileManager.createDirectory(at: model.windowsTPMStateURL, withIntermediateDirectories: true)

        let bootDevice = try model.bootDevice
        if !bootDevice.diskImageExists(for: model) {
            let settings = DiskImageGenerator.ImageSettings(for: try model.bootDiskImage, in: model)
            try await DiskImageGenerator.generateImage(with: settings)
        }
    }

    /// Unix socket paths are limited to 104 bytes, which the virtual machine's bundle path could easily exceed.
    private static func makeRuntimeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "vbq-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        return url
    }

    private func launchTPM(toolchain: QEMUToolchain, socketURL: URL) throws {
        let process = Process()
        process.executableURL = toolchain.swtpmURL
        process.arguments = [
            "socket",
            "--tpm2",
            "--tpmstate", "dir=\(model.windowsTPMStateURL.path.replacingOccurrences(of: ",", with: ",,"))",
            "--ctrl", "type=unixio,path=\(socketURL.path)",
            "--log", "file=\(model.swtpmLogURL.path.replacingOccurrences(of: ",", with: ",,")),level=1",
            "--terminate",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        swtpmProcess = process
    }

    /// swtpm is started with `--terminate`, so connecting to it to find out whether it's ready would make it exit.
    private func waitForTPMSocket(at url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while !FileManager.default.fileExists(atPath: url.path) {
            guard swtpmProcess?.isRunning == true else {
                throw Failure("The TPM emulator failed to start. Check \(model.swtpmLogURL.path) for details.")
            }
            guard clock.now < deadline else {
                throw Failure("Timed out waiting for the TPM emulator to start.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Reports QEMU's own output when it exits before a connection to it could be made, since that's what explains the failure.
    private func connectToQEMU<T>(_ connect: () async throws -> T) async throws -> T {
        do {
            return try await connect()
        } catch {
            if let qemuProcess, !qemuProcess.isRunning {
                throw Failure("QEMU failed to start. \(recentLogOutput)")
            }
            throw error
        }
    }

    private func launchQEMU(toolchain: QEMUToolchain, arguments: [String]) throws {
        FileManager.default.createFile(atPath: model.qemuLogURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: model.qemuLogURL)

        logger.debug("Launching QEMU with arguments: \(arguments.joined(separator: " "), privacy: .public)")

        let process = Process()
        process.executableURL = toolchain.qemuURL
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            try? logHandle.close()
            Task { @MainActor in self?.handleQEMUExit(status: status) }
        }

        try process.run()

        qemuProcess = process
    }

    private func handle(_ event: QMPClient.Event) {
        logger.debug("QEMU event: \(event.name, privacy: .public)")

        switch event.name {
        case "SHUTDOWN":
            isStopExpected = true
        case "STOP":
            if state == .running { state = .paused }
        case "RESUME":
            if state == .paused { state = .running }
        default:
            break
        }
    }

    private func handleQEMUExit(status: Int32) {
        /// Exiting during startup is reported by `start()`, which fails as a result, and exiting to restart is expected.
        guard qemuProcess != nil, state != .starting, !isRestarting else { return }

        logger.debug("QEMU exited with status \(status)")

        let error: Error?
        if isStopExpected || status == 0 {
            error = nil
        } else {
            error = Failure("QEMU exited unexpectedly (status \(status)). \(recentLogOutput)")
        }

        Task {
            await tearDown()
            reportStop(error: error)
        }
    }

    private var recentLogOutput: String {
        guard let log = try? String(contentsOf: model.qemuLogURL, encoding: .utf8) else { return "" }
        return log.split(separator: "\n").suffix(5).joined(separator: "\n")
    }

    private func waitForQEMUExit(timeout: Duration) async {
        guard let process = qemuProcess else { return }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            logger.warning("QEMU didn't exit in time, terminating it")
            process.terminate()
        }

        /// QEMU can be stuck badly enough to ignore being asked to terminate, so it's then ended outright.
        let killDeadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < killDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            logger.warning("QEMU didn't terminate, ending it")
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func tearDown() async {
        guestAgentInfo.detach()
        guestAgentServer?.close()
        guestAgentServer = nil
        guestAgent?.close()
        guestAgent = nil

        clipboardSync?.stop()
        clipboardSync = nil
        display?.onFrame = nil
        display?.onDisconnect = nil
        display?.close()
        display = nil

        monitor?.close()
        monitor = nil

        if let qemuProcess, qemuProcess.isRunning {
            qemuProcess.terminate()
        }
        qemuProcess = nil

        if let swtpmProcess, swtpmProcess.isRunning {
            swtpmProcess.terminate()
        }
        swtpmProcess = nil

        if let runtimeDirectoryURL {
            try? FileManager.default.removeItem(at: runtimeDirectoryURL)
        }
        runtimeDirectoryURL = nil

        latestFrame = nil
    }

    private func reportStop(error: Error?) {
        state = .stopped

        guard !didReportStop else { return }
        didReportStop = true

        onStop?(error)
    }

    private func deliver(_ frame: CGImage) {
        latestFrame = frame

        for observer in frameObservers.values {
            observer(frame)
        }
    }
}
