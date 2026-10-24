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
    private var guestAgentServer: GuestAgentServer?
    private var runtimeDirectoryURL: URL?
    private var isStopExpected = false
    private var didReportStop = false
    private var isRestarting = false

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

    func start() async throws {
        guard state == .stopped else { return }

        state = .starting
        isStopExpected = false
        didReportStop = false

        do {
            try await launch()
            state = .running
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

    private func launch() async throws {
        let toolchain = try QEMUToolchain.current()

        try await prepareBundle(toolchain: toolchain)

        let runtimeDirectoryURL = try Self.makeRuntimeDirectory()
        self.runtimeDirectoryURL = runtimeDirectoryURL

        let paths = QEMULaunchConfiguration.RuntimePaths(
            monitorSocket: runtimeDirectoryURL.appending(path: "qmp.sock"),
            displaySocket: runtimeDirectoryURL.appending(path: "vnc.sock"),
            tpmSocket: runtimeDirectoryURL.appending(path: "tpm.sock"),
            agentSocket: runtimeDirectoryURL.appending(path: "agent.sock")
        )

        let configuration = QEMULaunchConfiguration(
            model: model,
            toolchain: toolchain,
            runtimePaths: paths,
            installDiskURL: installDiskURL,
            driversDiskURL: driversDiskURL,
            displayAdapter: displayAdapter
        )
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

        try await monitor.execute("cont")
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
    }

    private func tearDown() async {
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
