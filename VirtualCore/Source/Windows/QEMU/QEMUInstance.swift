import Foundation
import Combine
import VirtualWormhole
import OSLog

/// Runs a virtual machine with QEMU on behalf of ``VMController``.
@MainActor
final class QEMUInstance: VMEngineInstance {
    var options = VMSessionOptions.default

    let virtualMachineModel: VBVirtualMachine
    /// The virtual machine as it was when a session was saved, while that session runs.
    private var restoredModel: VBVirtualMachine?
    var effectiveModel: VBVirtualMachine { restoredModel ?? virtualMachineModel }
    let isRecoveryBoot = false

    /// Guests that run with QEMU don't have the guest app.
    @Published private var isGuestAppConnected = false
    var isGuestAppConnectedPublisher: Published<Bool>.Publisher { $isGuestAppConnected }

    let activeBridgeInterfaceIdentifiers = Set<String>()
    let hasBridgedNetworkAttachments = false

    private let library: VMLibraryController
    private let onVMStop: (Error?) -> Void
    private var machine: QEMUVirtualMachine?
    private var setupCompletionTask: Task<Void, Never>?
    /// Set while the virtual machine is released on purpose, which isn't news for whoever is told that it stopped.
    private var isReleasing = false
    /// Whether Windows can be switched to another resolution. See ``QEMUVirtualMachine/canSwitchResolution``.
    var canSwitchResolution: Bool { machine?.canSwitchResolution == true }

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "QEMUInstance")

    init(with vm: VBVirtualMachine, library: VMLibraryController, onVMStop: @escaping (Error?) -> Void) {
        self.virtualMachineModel = vm
        self.library = library
        self.onVMStop = onVMStop
    }

    var currentRuntime: (runtime: VMRuntime, isPaused: Bool)? {
        guard let machine else { return nil }

        switch machine.state {
        case .running: return (.qemu(machine), false)
        case .paused: return (.qemu(machine), true)
        case .starting, .stopping, .stopped: return nil
        }
    }

    func startVM() async throws {
        let model = virtualMachineModel
        let devices = try await prepareDevices(forInstallation: options.bootOnInstallDevice)
        let isUnattendedInstallation = devices.installDiskURL != nil && (try? model.windowsUnattendedSetup()) != nil

        let machine = QEMUVirtualMachine(model: model, installDiskURL: devices.installDiskURL, driversDiskURL: devices.driversDiskURL, displayAdapter: devices.displayAdapter)
        try await start(machine)

        if isUnattendedInstallation {
            restartWhenSetupFinishes(machine)
        }
    }

    private func start(_ machine: QEMUVirtualMachine, restoring restoration: QEMUVirtualMachine.Restoration? = nil) async throws {
        machine.onStop = { [weak self] error in
            self?.handleStop(error)
        }
        self.machine = machine
        guestAgentInfoObservation = machine.guestAgentInfo.publisher.sink { [guestAgentInfo] in guestAgentInfo.send($0) }

        library.registerBootedVM(self)

        do {
            try await machine.start(restoring: restoration)
        } catch {
            self.machine = nil
            guestAgentInfoObservation = nil
            library.unregisterBootedVM(self)
            throw error
        }
    }

    private func prepareDevices(forInstallation: Bool) async throws -> QEMUVirtualMachine.Devices {
        let model = virtualMachineModel
        let installDiskURL = try await prepareInstallDisk(forInstallation: forInstallation)
        await updateDriversIfNeeded()
        let driversDiskURL = try await WindowsDriversDisk.prepare(for: model)

        /// Windows Setup installs the drivers from the drivers disk before it finishes, as long as it hasn't got that far yet.
        /// Setup can't use the virtio GPU, so the framebuffer is used until it's done.
        if installDiskURL != nil, driversDiskURL != nil, !model.windowsIsInstalled {
            FileManager.default.createFile(atPath: model.windowsGuestDriversMarkerURL.path, contents: nil)
        }
        let displayAdapter: QEMULaunchConfiguration.DisplayAdapter = installDiskURL == nil && model.windowsGuestDriversInstalled ? .virtioGPU : .framebuffer

        return QEMUVirtualMachine.Devices(installDiskURL: installDiskURL, driversDiskURL: driversDiskURL, displayAdapter: displayAdapter)
    }

    /// What's installed in Windows from the drivers disk changes, such as when the clipboard agent was added, so the drivers
    /// are updated when a virtual machine starts if an earlier version was installed. If that fails, the virtual machine
    /// starts without the drivers disk.
    private func updateDriversIfNeeded() async {
        guard WindowsDrivers.isEarlierVersionInstalled else { return }

        logger.notice("Updating the Windows drivers")

        do {
            try await WindowsDrivers.install(onOutput: { [logger] line in
                logger.info("\(line, privacy: .public)")
            })
        } catch {
            logger.error("Couldn't update the Windows drivers: \(error, privacy: .public)")
        }
    }

    /// Windows signs in by itself once an unattended installation has finished, still using the framebuffer and with the
    /// installer attached. The virtual machine is then restarted without the installer, so that it uses the virtio GPU.
    private func restartWhenSetupFinishes(_ machine: QEMUVirtualMachine) {
        setupCompletionTask?.cancel()
        setupCompletionTask = Task { [weak self, model = virtualMachineModel] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))

                guard let self, self.machine === machine, machine.state == .running else { return }

                let messages = (try? String(contentsOf: model.windowsGuestStatusURL, encoding: .utf8)) ?? ""
                guard WindowsGuestStatus.lastMessage(in: messages) == WindowsGuestStatus.signedInMessage else { continue }

                logger.notice("Windows Setup has finished, restarting without the installer")

                do {
                    try await machine.restart {
                        try await self.prepareDevices(forInstallation: false)
                    }
                } catch {
                    logger.error("Failed to restart after Windows Setup: \(error, privacy: .public)")
                }
                return
            }
        }
    }

    func pause() async throws {
        try await requireMachine().pause()
    }

    func resume() async throws {
        try await requireMachine().resume()
    }

    func stop() async throws {
        try await requireMachine().requestStop()
    }

    func forceStop() async throws {
        try await requireMachine().forceStop()
    }

    func reconnectNetwork() throws {
        throw Failure("Reconnecting the network isn’t available for Windows virtual machines.")
    }

    func changeBridgeInterface(to interfaceIdentifier: String) throws {
        throw Failure("Bridged networking isn’t available for Windows virtual machines.")
    }

    func stopGuestCommunication() async { }

    var guestAgentConnection: GuestAgentConnection? { machine?.guestAgentConnection }

    /// Each start makes a new machine, so what its agent says is passed on from whichever machine is running.
    private let guestAgentInfo = CurrentValueSubject<GuestAgentInfo?, Never>(nil)
    private var guestAgentInfoObservation: AnyCancellable?
    var guestAgentInfoPublisher: AnyPublisher<GuestAgentInfo?, Never> { guestAgentInfo.eraseToAnyPublisher() }

    /// The installer stays attached until Windows has been installed, even if setup was interrupted, and is removed afterwards
    /// to free up the space it takes. It's created again from the original disc image if it's needed later.
    ///
    /// - Parameter forInstallation: Whether to attach the installer even if Windows has been installed.
    private func prepareInstallDisk(forInstallation: Bool) async throws -> URL? {
        let model = virtualMachineModel
        let diskURL = model.windowsInstallDiskURL
        let diskExists = FileManager.default.fileExists(atPath: diskURL.path)

        guard forInstallation || !model.windowsIsInstalled else {
            if diskExists {
                try FileManager.default.removeItem(at: diskURL)
            }
            /// Windows Setup has used the settings by now, and they may contain a password.
            try model.removeWindowsUnattendedSetup()
            return nil
        }

        guard !diskExists else { return diskURL }

        guard let isoURL = model.metadata.installImageURL else {
            throw Failure("The Windows installer for this virtual machine is unknown. Create a new virtual machine to install Windows.")
        }

        try await WindowsInstallDisk.create(from: isoURL, at: diskURL, setup: try model.windowsUnattendedSetup()) { _ in }

        return diskURL
    }

    private func requireMachine() throws -> QEMUVirtualMachine {
        guard let machine else { throw Failure("The virtual machine instance is not available.") }
        return machine
    }

    private func handleStop(_ error: Error?) {
        setupCompletionTask?.cancel()
        setupCompletionTask = nil
        machine = nil
        restoredModel = nil
        guestAgentInfoObservation = nil
        guestAgentInfo.send(nil)
        library.unregisterBootedVM(self)

        guard !isReleasing else { return }
        onVMStop(error)
    }
}

// MARK: - Saved Sessions

extension QEMUInstance: VMSessionSavingInstance {
    var runtimeSaveEligibility: SavedSessionEligibility {
        guard let machine else { return .supported }

        return SavedSessionEligibility(issues: machine.isInstallerAttached ? [.windowsSetupInProgress] : [])
    }

    func pauseForSaving() async throws -> Bool {
        let machine = try requireMachine()

        switch machine.state {
        case .running:
            try await machine.pause()
            return true
        case .paused:
            return false
        case .starting, .stopping, .stopped:
            throw Failure("The virtual machine can’t be saved in its current state.")
        }
    }

    /// The disks and the UEFI variables are captured as files. The TPM's state is part of QEMU's own state, and the drivers
    /// disk is only ever changed while Windows is shut down, so it's still the same when the session is restored.
    func makeSavedSessionCapturePlan(wasPausedBeforeSave: Bool) async throws -> SavedSessionCapturePlan {
        let machine = try requireMachine()
        let model = effectiveModel

        var resources = [SavedSessionCapturePlan.ResourceSource]()

        for device in model.configuration.hardware.storageDevices where device.isEnabled {
            guard case .managedImage(let image) = device.backing else {
                throw SavedSessionError.notEligible(.externalDiskImage(device.displayName))
            }

            let url = model.diskImageURL(for: image)

            resources.append(.init(id: device.id, role: .disk, sourceURL: url, workingPath: url.lastPathComponent))
        }

        let variablesURL = model.windowsEFIVariablesURL
        resources.append(.init(id: "firmwareVariables", role: .firmwareVariables, sourceURL: variablesURL, workingPath: variablesURL.lastPathComponent))

        return SavedSessionCapturePlan(
            resources: resources,
            configuration: model.configuration,
            runtimeDescription: nil,
            screenshotSourceURL: nil,
            wasPausedBeforeSave: wasPausedBeforeSave,
            memorySize: model.configuration.hardware.memorySize,
            qemuDescription: try await machine.savedSessionDescription(),
            stateFileName: SavedSessionLayout.qemuStateFileName,
            screenshotImage: machine.currentFrame()
        )
    }

    func saveMachineState(to url: URL) async throws {
        try await requireMachine().saveState(to: url)
    }

    /// QEMU has nothing left to do once its state has been saved, so it's told to quit.
    func tearDownAfterSave() async throws {
        await releaseStoppedVirtualMachine()
    }

    func releaseStoppedVirtualMachine() async {
        guard let machine else { return }

        isReleasing = true
        defer { isReleasing = false }

        await machine.forceStop()
    }

    func restoreSession(_ preparation: SavedSessionRestorePreparation, onConstructed: (VMRuntime) -> Void) async throws {
        guard let description = preparation.manifest.qemuDescription else {
            throw SavedSessionError.invalidManifest("The saved session wasn’t made for a Windows virtual machine.")
        }

        var model = virtualMachineModel
        model.configuration = preparation.configuration

        let driversDiskURL = description.hasDriversDisk ? model.windowsDriversDiskURL : nil
        if let driversDiskURL, !FileManager.default.fileExists(atPath: driversDiskURL.path) {
            throw SavedSessionError.missingResource(driversDiskURL.lastPathComponent)
        }

        let machine = QEMUVirtualMachine(
            model: model,
            installDiskURL: nil,
            driversDiskURL: driversDiskURL,
            displayAdapter: description.displayAdapter,
            network: description.network ?? .qemu
        )

        guard try machine.comparableArguments() == QEMULaunchConfiguration.withoutConnections(description.arguments) else {
            throw SavedSessionError.configurationChanged("Hypervisaur starts Windows virtual machines differently from when this session was saved.")
        }

        restoredModel = model

        onConstructed(.qemu(machine))

        do {
            try await start(machine, restoring: QEMUVirtualMachine.Restoration(stateFileURL: preparation.stateFileURL, machineType: description.machineType))
        } catch {
            restoredModel = nil
            logger.error("Restoring the saved session failed: \(error, privacy: .public)")
            throw error
        }

        logger.log("Restored the saved state, the virtual machine is paused")
    }

    func resumeRestoredSession() async throws {
        try await requireMachine().resume()
    }

    /// QEMU quits once its state has been saved, so there's nothing that carries on and needs reconnecting.
    func restartGuestCommunication() async { }
}
