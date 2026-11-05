import Foundation
import OSLog
import ManagedPreferencesKit

/// The networks that a Windows virtual machine's network devices are connected to while QEMU runs. QEMU connects each device
/// to its network with a stream network device.
///
/// NAT devices are connected to the `HypervisaurNetwork` program that comes with Hypervisaur. QEMU's own user networking gives
/// the guest the Mac's loopback interface at the host's address, and at the other addresses in its network that it doesn't use
/// for something else, so programs in the guest could reach services on the Mac that only accept connections from the Mac
/// itself. QEMU has no option to stop that, but libslirp, which QEMU's user networking is made with, does. `HypervisaurNetwork`
/// runs libslirp with it, and with the same addresses as QEMU's user networking. The first NAT device's network also serves the
/// shared folders, as QEMU's user networking did. See ``WindowsFolderSharing``. A virtual machine whose devices are all bridged
/// has a network of its own that only serves the shared folders instead. See ``QEMULaunchConfiguration/hasFolderSharingNetwork(_:)``.
/// Each of these networks listens on its socket in QEMU's runtime directory, and exits once QEMU disconnects from it.
///
/// Bridged devices are connected to one of the Mac's network interfaces by Hypervisaur itself. See ``QEMUBridgedNetwork``.
/// They can be bridged to another interface while the virtual machine runs, and are bridged again when their interface comes
/// back, such as when a cable is plugged in again. Windows is told that the device's cable is unplugged while it isn't bridged,
/// so that it gets a new address once it's bridged again.
@MainActor
final class QEMUNetwork {
    static let helperName = "HypervisaurNetwork"

    nonisolated private static let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "QEMUNetwork")

    /// How long to wait between attempts to bridge a device again, which carry on until it's bridged.
    private static let reconnectionDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// How long to wait after an interface comes back before bridging to it, while its link settles.
    private static let hostInterfaceDebounceDelay = Duration.seconds(1)

    private struct BridgedDevice {
        let index: Int
        let network: QEMUBridgedNetwork
        var interfaceIdentifier: String
        /// Whether the device is bridged to its interface, rather than waiting to be or disconnected by policy.
        var isConnected: Bool
    }

    private struct ReconnectionTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum ReconnectionReason: String {
        case manualRequest
        case bridgeInterfaceChanged
        case hostInterfaceBecameActive
    }

    private let processes: [Process]
    private var bridgedDevices: [BridgedDevice]
    /// Where Windows is told whether each bridged device's cable is plugged in. Set once QEMU's monitor is connected.
    private var monitor: QMPClient?
    private var linkMonitor: HostInterfaceLinkMonitor?
    private var policyObservation: ManagedPreferenceObservation?
    private var reconnectionTasks: [Int: ReconnectionTask] = [:]
    private var isStopped = false

    private init(processes: [Process], bridgedDevices: [BridgedDevice]) {
        self.processes = processes
        self.bridgedDevices = bridgedDevices
    }

    /// Starts a network for each of the virtual machine's network devices, and waits until QEMU can connect to them.
    static func start(
        for model: VBVirtualMachine,
        toolchain: QEMUToolchain,
        runtimePaths: QEMULaunchConfiguration.RuntimePaths,
        folderSharing: WindowsFolderSharing?
    ) async throws -> QEMUNetwork {
        let devices = model.configuration.hardware.networkDevices
        let folderSharingDeviceIndex = devices.firstIndex { $0.kind == .NAT }
        let hasFolderSharingNetwork = QEMULaunchConfiguration.hasFolderSharingNetwork(model.configuration.hardware)

        var processes = [Process]()
        var bridgedDevices = [BridgedDevice]()

        do {
            /// The networks that `HypervisaurNetwork` runs share a log, which starts afresh each time the virtual machine does.
            var logHandle: FileHandle?
            if folderSharingDeviceIndex != nil || hasFolderSharingNetwork {
                FileManager.default.createFile(atPath: model.networkLogURL.path, contents: nil)
                logHandle = try FileHandle(forWritingTo: model.networkLogURL)
            }
            defer { try? logHandle?.close() }

            for (index, device) in devices.enumerated() {
                let socketURL = runtimePaths.networkSocket(forDeviceAt: index)

                switch device.kind {
                case .NAT:
                    let sharing = index == folderSharingDeviceIndex ? folderSharing : nil
                    guard let logHandle else { preconditionFailure("The networks' log is opened when there are NAT devices") }
                    processes.append(try startHelperNetwork(at: socketURL, name: "device \(index)", isHostOnly: false, toolchain: toolchain, folderSharing: sharing, logHandle: logHandle))
                case .bridge:
                    bridgedDevices.append(try await startBridgedNetwork(at: socketURL, deviceIndex: index, device: device))
                }
            }

            var helperSocketURLs = devices.indices.filter { devices[$0].kind == .NAT }.map(runtimePaths.networkSocket(forDeviceAt:))

            if hasFolderSharingNetwork {
                guard let logHandle else { preconditionFailure("The networks' log is opened when there's a folder sharing network") }
                let socketURL = runtimePaths.folderSharingNetworkSocket
                processes.append(try startHelperNetwork(at: socketURL, name: "the shared folders", isHostOnly: true, toolchain: toolchain, folderSharing: folderSharing, logHandle: logHandle))
                helperSocketURLs.append(socketURL)
            }

            let network = QEMUNetwork(processes: processes, bridgedDevices: bridgedDevices)
            try await network.waitUntilListening(at: helperSocketURLs, logURL: model.networkLogURL)
            return network
        } catch {
            for process in processes where process.isRunning {
                process.terminate()
            }
            for device in bridgedDevices {
                device.network.close()
            }
            throw error
        }
    }

    /// - Parameter isHostOnly: Whether the network only reaches the shared folders, rather than being a NAT network.
    private static func startHelperNetwork(
        at socketURL: URL,
        name: String,
        isHostOnly: Bool,
        toolchain: QEMUToolchain,
        folderSharing: WindowsFolderSharing?,
        logHandle: FileHandle
    ) throws -> Process {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: helperName) else {
            throw Failure("\(helperName) is missing from Hypervisaur. Install Hypervisaur again.")
        }

        var arguments = isHostOnly ? ["--host-only"] : []
        arguments += [toolchain.slirpLibraryURL.path, socketURL.path]
        if let folderSharing {
            arguments += [WindowsFolderSharing.serverAddress, String(WindowsFolderSharing.serverPort), folderSharing.serverCommand]
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        process.terminationHandler = { process in
            guard process.terminationReason != .exit || process.terminationStatus != 0 else { return }
            Self.logger.error("The network of \(name, privacy: .public) stopped with status \(process.terminationStatus)")
        }
        try process.run()
        return process
    }

    /// Saved bridged devices start disconnected while bridged networking is disabled by policy, and are bridged to the
    /// interface they were set up with otherwise, which must be available.
    private static func startBridgedNetwork(at socketURL: URL, deviceIndex: Int, device: VBNetworkDevice) async throws -> BridgedDevice {
        let interfaceIdentifier = try bridgeInterfaceIdentifier(for: device)
        let network = try QEMUBridgedNetwork(socketURL: socketURL, logger: logger)

        guard !VirtualBuddyManagedPreferences.bridgedNetworkingDisabled else {
            VirtualBuddyManagedPreferences.logger.notice("Bridged network adapter disconnected by DisableBridgedNetworking")
            return BridgedDevice(index: deviceIndex, network: network, interfaceIdentifier: interfaceIdentifier, isConnected: false)
        }

        do {
            try await network.connect(toInterface: interfaceIdentifier)
        } catch {
            network.close()
            throw error
        }

        return BridgedDevice(index: deviceIndex, network: network, interfaceIdentifier: interfaceIdentifier, isConnected: true)
    }

    /// Automatic bridges are bridged to the first interface that can be bridged to when the virtual machine starts, and stay
    /// bridged to it while it runs, so that the guest's address doesn't unexpectedly move to another network.
    private static func bridgeInterfaceIdentifier(for device: VBNetworkDevice) throws -> String {
        let available = VBNetworkDevice.bridgeInterfaces.map(\.id)

        guard device.id != VBNetworkDeviceInterface.automatic.id else {
            return try available.first.require("There are no network interfaces available on the host for bridging.")
        }

        guard available.contains(device.id) else {
            throw Failure("The bridged network interface \(device.id.quoted) is not available.")
        }

        return device.id
    }

    /// Each NAT network makes its socket once it's listening, so QEMU can connect once they're all there.
    private func waitUntilListening(at socketURLs: [URL], logURL: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while !socketURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            guard processes.allSatisfy(\.isRunning) else {
                throw Failure("The virtual machine’s network failed to start. Check \(logURL.path) for details.")
            }
            guard clock.now < deadline else {
                throw Failure("Timed out waiting for the virtual machine’s network to start.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - While QEMU Runs

    /// Tells Windows which bridged devices' cables are unplugged, and starts watching the interfaces they're bridged to and
    /// the bridged networking policy. Called once QEMU's monitor is connected, before the guest runs, and again after a saved
    /// session's state has been loaded, since the state includes whether each cable was plugged in.
    func attach(to monitor: QMPClient) async {
        guard !isStopped else { return }

        self.monitor = monitor

        for device in bridgedDevices {
            await setGuestLink(ofDeviceAt: device.index, isUp: device.isConnected)
        }

        guard !bridgedDevices.isEmpty else { return }

        if policyObservation == nil {
            policyObservation = VirtualBuddyManagedPreferences.reader()
                .observeChanges(for: .disableBridgedNetworking) { [weak self] in
                    self?.enforcePolicy()
                }
        }

        startMonitoringHostInterfaces()
        enforcePolicy()
    }

    /// The interfaces that the bridged devices are bridged to, or will be once they're connected.
    var bridgeInterfaceIdentifiers: Set<String> {
        Set(bridgedDevices.map(\.interfaceIdentifier))
    }

    var hasBridgedDevices: Bool { !bridgedDevices.isEmpty }

    /// Bridges each bridged device to its interface again, retrying until it can be.
    func reconnect() throws {
        guard !bridgedDevices.isEmpty else {
            throw Failure("Only bridged network devices can be reconnected in Windows virtual machines.")
        }

        for device in bridgedDevices {
            scheduleReconnection(ofDeviceAt: device.index, after: .zero, reason: .manualRequest)
        }

        Self.logger.info("Manual network reconnection scheduled for \(self.bridgedDevices.count) device(s)")
    }

    /// Bridges each bridged device to the interface with the identifier.
    func changeBridgeInterface(to interfaceIdentifier: String) throws {
        guard !VirtualBuddyManagedPreferences.bridgedNetworkingDisabled else {
            Self.logger.notice("Bridge interface change denied by DisableBridgedNetworking")
            throw Failure("Bridged networking is disabled by your organization.")
        }
        guard VBNetworkDevice.bridgeInterfaces.contains(where: { $0.id == interfaceIdentifier }) else {
            throw Failure("The bridged network interface \(interfaceIdentifier.quoted) is not currently available.")
        }
        guard !bridgedDevices.isEmpty else {
            throw Failure("This virtual machine has no bridged network devices.")
        }

        for index in bridgedDevices.indices {
            bridgedDevices[index].interfaceIdentifier = interfaceIdentifier
        }

        stopMonitoringHostInterfaces()
        startMonitoringHostInterfaces()

        for device in bridgedDevices {
            scheduleReconnection(ofDeviceAt: device.index, after: .zero, reason: .bridgeInterfaceChanged)
        }

        Self.logger.info("Changed \(self.bridgedDevices.count) bridged network device(s) to host interface \(interfaceIdentifier, privacy: .public)")
    }

    /// Stops the networks that are still running. The NAT networks stop by themselves once QEMU has exited.
    func stop() {
        isStopped = true

        for reconnection in reconnectionTasks.values {
            reconnection.task.cancel()
        }
        reconnectionTasks.removeAll()

        stopMonitoringHostInterfaces()
        policyObservation = nil
        monitor = nil

        for device in bridgedDevices {
            device.network.close()
        }

        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Policy

    /// Disconnects the bridged devices while bridged networking is disabled by policy. They stay disconnected once the policy
    /// is lifted, until they're reconnected or the virtual machine starts again, as for virtual machines that Virtualization runs.
    private func enforcePolicy() {
        guard !isStopped, VirtualBuddyManagedPreferences.bridgedNetworkingDisabled else { return }

        stopMonitoringHostInterfaces()

        for index in bridgedDevices.indices {
            let device = bridgedDevices[index]
            reconnectionTasks.removeValue(forKey: device.index)?.task.cancel()

            guard device.isConnected else { continue }

            bridgedDevices[index].isConnected = false
            VirtualBuddyManagedPreferences.logger.notice("Bridged network adapter disconnected by DisableBridgedNetworking")

            Task {
                await self.setGuestLink(ofDeviceAt: device.index, isUp: false)
                await device.network.disconnect()
            }
        }
    }

    // MARK: - Reconnecting

    private func startMonitoringHostInterfaces() {
        guard !isStopped, linkMonitor == nil, !VirtualBuddyManagedPreferences.bridgedNetworkingDisabled else { return }

        linkMonitor = HostInterfaceLinkMonitor(interfaceIdentifiers: bridgeInterfaceIdentifiers, logger: Self.logger) { [weak self] interfaceIdentifier in
            self?.handleHostInterfaceBecameActive(interfaceIdentifier)
        }
    }

    private func stopMonitoringHostInterfaces() {
        linkMonitor?.stop()
        linkMonitor = nil
    }

    private func handleHostInterfaceBecameActive(_ interfaceIdentifier: String) {
        let devices = bridgedDevices.filter { $0.interfaceIdentifier == interfaceIdentifier }
        guard !devices.isEmpty else { return }

        Self.logger.info("Host bridge interface \(interfaceIdentifier, privacy: .public) became active; bridging \(devices.count) device(s) to it again")

        for device in devices {
            scheduleReconnection(ofDeviceAt: device.index, after: Self.hostInterfaceDebounceDelay, reason: .hostInterfaceBecameActive)
        }
    }

    /// Unplugs the device's cable while it's bridged to its interface again, so that Windows gets an address on that
    /// interface's network once it's plugged back in, and tries again until it can be bridged.
    private func scheduleReconnection(ofDeviceAt deviceIndex: Int, after initialDelay: Duration, reason: ReconnectionReason) {
        guard !isStopped else { return }

        reconnectionTasks.removeValue(forKey: deviceIndex)?.task.cancel()

        guard !VirtualBuddyManagedPreferences.bridgedNetworkingDisabled else {
            enforcePolicy()
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            var delay = initialDelay
            var attempt = 0

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard let self, !self.isStopped,
                      let position = self.bridgedDevices.firstIndex(where: { $0.index == deviceIndex })
                else { return }

                guard !VirtualBuddyManagedPreferences.bridgedNetworkingDisabled else {
                    self.enforcePolicy()
                    return
                }

                let device = self.bridgedDevices[position]
                attempt += 1

                Self.logger.info("Bridging network device \(deviceIndex) to \(device.interfaceIdentifier, privacy: .public) (reason=\(reason.rawValue, privacy: .public), attempt=\(attempt))")

                self.bridgedDevices[position].isConnected = false
                await self.setGuestLink(ofDeviceAt: deviceIndex, isUp: false)

                do {
                    try await device.network.connect(toInterface: device.interfaceIdentifier)
                    try Task.checkCancellation()

                    guard let position = self.bridgedDevices.firstIndex(where: { $0.index == deviceIndex }) else { return }
                    self.bridgedDevices[position].isConnected = true
                    await self.setGuestLink(ofDeviceAt: deviceIndex, isUp: true)

                    Self.logger.info("Bridged network device \(deviceIndex) to \(device.interfaceIdentifier, privacy: .public)")
                    self.reconnectionDidFinish(forDeviceAt: deviceIndex, id: id)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.error("Failed to bridge network device \(deviceIndex) on attempt \(attempt): \(error, privacy: .public)")
                }

                delay = Self.reconnectionDelays[min(attempt, Self.reconnectionDelays.count - 1)]
            }
        }
        reconnectionTasks[deviceIndex] = ReconnectionTask(id: id, task: task)
    }

    private func reconnectionDidFinish(forDeviceAt deviceIndex: Int, id: UUID) {
        guard reconnectionTasks[deviceIndex]?.id == id else { return }
        reconnectionTasks.removeValue(forKey: deviceIndex)
    }

    private func setGuestLink(ofDeviceAt deviceIndex: Int, isUp: Bool) async {
        guard let monitor else { return }

        do {
            try await monitor.execute("set_link", arguments: ["name": QEMULaunchConfiguration.netdevID(forDeviceAt: deviceIndex), "up": isUp])
        } catch {
            Self.logger.error("Couldn’t tell Windows that network device \(deviceIndex)’s cable is \(isUp ? "plugged in" : "unplugged", privacy: .public): \(error, privacy: .public)")
        }
    }
}
