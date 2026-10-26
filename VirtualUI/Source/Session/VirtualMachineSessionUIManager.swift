import SwiftUI
import VirtualCore
import Combine
import OSLog

/// Controls active virtual machine sessions, managing the lifecycle of session windows, controllers, and opening VMs from files or URLs.
@MainActor
public final class VirtualMachineSessionUIManager: ObservableObject {
    private let logger = Logger(for: VirtualMachineSessionUIManager.self)
    
    public let focusedSessionChanged = PassthroughSubject<WeakReference<VirtualMachineSessionUI>?, Never>()

    public static let shared = VirtualMachineSessionUIManager()

    private let openWindow = OpenCocoaWindowAction.default

    /// Every session that has a window, or a virtual machine that's running in the background.
    @Published private(set) var sessions = [VBVirtualMachine.ID: VirtualMachineSessionUI]()

    /// The sessions whose window is closed while their virtual machine carries on running. See `sessionWindowDidClose(for:library:)`.
    @Published private(set) var backgroundSessionIDs = Set<VBVirtualMachine.ID>()

    /// Follows each virtual machine that runs in the background, so that its session goes away once it stops.
    private var backgroundStateObservers = [VBVirtualMachine.ID: AnyCancellable]()

    /// The background sessions whose virtual machine is kept from going to sleep. See ``VMSleepPrevention``.
    @Published private(set) var awakeSessionIDs = Set<VBVirtualMachine.ID>()

    private let terminationPresenter = TerminationPresenter()

    /// Decides whether the app may quit while virtual machines are running. See `prepareForTermination()`.
    private(set) lazy var terminationCoordinator = SessionTerminationCoordinator(
        presenter: terminationPresenter,
        holdTermination: { Self.holdTermination() }
    )

    private init() {
        terminationPresenter.manager = self
    }

    private func createSession(for vm: VBVirtualMachine, library: VMLibraryController, options: VMSessionOptions?) -> VirtualMachineSessionUI {
        let ui = VirtualMachineSessionUI(with: vm, library: library, options: options)

        sessions[vm.id] = ui

        return ui
    }

    public func session(for vm: VBVirtualMachine) -> VirtualMachineSessionUI? { sessions[vm.id] }

    func sessionIfAvailable(withID id: VBVirtualMachine.ID) -> VirtualMachineSessionUI? { sessions[id] }

    /// Whether the virtual machine is running without a window.
    public func isRunningInBackground(_ vm: VBVirtualMachine) -> Bool { backgroundSessionIDs.contains(vm.id) }

    /// Whether the virtual machine is running in the background and kept from going to sleep.
    public func isKeptAwake(_ vm: VBVirtualMachine) -> Bool { awakeSessionIDs.contains(vm.id) }

    /// Starts or stops keeping a virtual machine that runs in the background awake. Virtual machines with a window
    /// are left to sleep as they normally would.
    func setKeepsAwake(_ keepsAwake: Bool, for session: VirtualMachineSessionUI) {
        let vmID = session.virtualMachine.id

        if keepsAwake, backgroundSessionIDs.contains(vmID) {
            session.sleepPrevention.start()
            awakeSessionIDs.insert(vmID)
        } else {
            session.sleepPrevention.stop()
            awakeSessionIDs.remove(vmID)
        }
    }

    /// Takes new previews of what every running virtual machine shows, one at a time.
    func refreshPreviews() async {
        for session in Array(sessions.values) {
            guard !Task.isCancelled else { return }
            await session.refreshPreview()
        }
    }

    public func launch(_ vm: VBVirtualMachine, library: VMLibraryController, options: VMSessionOptions?) {
        /// A virtual machine on a disk that has been disconnected can't be opened, and its missing files don't mean that
        /// it needs installing.
        guard FileManager.default.fileExists(atPath: vm.bundleURL.path(percentEncoded: false)) else {
            library.loadMachines()
            presentMissingVirtualMachineAlert(for: vm)
            return
        }

        guard !vm.needsInstall else {
            recoverInstallation(for: vm, library: library)
            return
        }

        if let existingSession = session(for: vm) {
            existingSession.update(with: options)

            if backgroundSessionIDs.contains(vm.id) {
                openWindow(for: existingSession, library: library)
            } else {
                existingSession.bringToFront()
            }
        } else {
            launchNewSession(for: vm, library: library, options: options)
        }
    }

    private func presentMACAddressConflictAlert(conflicts: [MACAddressConflict]) async -> MACAddressConflictResolution {
        let alert = NSAlert()
        alert.messageText = "Duplicate MAC Address"
        let formattedConflicts = conflicts
            .sorted { $0.macAddress < $1.macAddress }
            .map { "\($0.macAddress) used by \"\($0.vmName)\"" }
            .joined(separator: "\n")
        alert.informativeText = "A network device on this virtual machine shares a MAC address with another virtual machine that's already running:\n\n\(formattedConflicts)\n\nRunning multiple virtual machines with the same MAC address may cause network connectivity issues."
        alert.addButton(withTitle: "Randomize MAC address & Continue")
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Cancel")

        let response: NSApplication.ModalResponse
        if let window = NSApp?.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        switch response {
        case .alertFirstButtonReturn: return .randomize
        case .alertSecondButtonReturn: return .continueAnyway
        default: return .cancel
        }
    }

    private func launchNewSession(for vm: VBVirtualMachine, library: VMLibraryController, options: VMSessionOptions?) {
        let session = createSession(for: vm, library: library, options: options)

        session.controller.macAddressConflictHandler = { [weak self] conflicts in
            guard let self else { return .cancel }
            return await self.presentMACAddressConflictAlert(conflicts: conflicts)
        }

        openWindow(for: session, library: library)
    }

    /// Opens the window of a new session, or of one whose virtual machine has been running in the background.
    private func openWindow(for session: VirtualMachineSessionUI, library: VMLibraryController) {
        let vmID = session.virtualMachine.id

        setKeepsAwake(false, for: session)
        backgroundSessionIDs.remove(vmID)
        backgroundStateObservers[vmID] = nil

        /// The window opens at the size of the virtual machine's display, as far as it fits on the screen.
        let preferredContentSize = session.fixedGuestDisplaySize
            ?? session.virtualMachine.configuration.hardware.displayDevices.first.map { CGSize(width: $0.width, height: $0.height) }

        openWindow(id: vmID, preferredContentSize: preferredContentSize) {
            VirtualMachineSessionView()
                .environmentObject(session)
                .environmentObject(session.controller)
                .environmentObject(library)
                .environmentObject(self)
        } onClose: { [weak self, weak library] in
            guard let self, let library else { return }
            sessionWindowDidClose(for: vmID, library: library)
        }
    }

    /// A session lives for as long as its window is open, or for as long as its virtual machine still needs stopping.
    /// A virtual machine whose window closes while it runs carries on in the background until it stops.
    private func sessionWindowDidClose(for vmID: VBVirtualMachine.ID, library: VMLibraryController) {
        guard let session = sessions[vmID] else { return }

        session.windowDidClose()

        guard session.needsStoppingBeforeClose else {
            discardSession(withID: vmID)
            return
        }

        logger.info("\(session.virtualMachine.name, privacy: .public) is running in the background")

        backgroundSessionIDs.insert(vmID)
        setKeepsAwake(VBSettings.current.keepsBackgroundVirtualMachinesAwake, for: session)

        /// The state is published before it changes, so it's looked at once the change has been made.
        backgroundStateObservers[vmID] = session.controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session, weak library] _ in
                MainActor.assumeIsolated {
                    guard let self, let session, let library else { return }
                    self.backgroundSessionStateDidChange(session, library: library)
                }
            }
    }

    private func backgroundSessionStateDidChange(_ session: VirtualMachineSessionUI, library: VMLibraryController) {
        let vmID = session.virtualMachine.id

        guard backgroundSessionIDs.contains(vmID) else { return }

        switch session.controller.state {
        case .stopped(.some), .recoveryRequired:
            /// Whatever went wrong while the virtual machine had no window is shown in its window, so that it isn't missed.
            logger.notice("\(session.virtualMachine.name, privacy: .public) needs attention, showing its window")
            openWindow(for: session, library: library)
        default:
            guard !session.needsStoppingBeforeClose else { return }

            logger.info("\(session.virtualMachine.name, privacy: .public) stopped in the background")
            discardSession(withID: vmID)
        }
    }

    private func discardSession(withID vmID: VBVirtualMachine.ID) {
        if let session = sessions[vmID] {
            setKeepsAwake(false, for: session)
        }

        backgroundSessionIDs.remove(vmID)
        backgroundStateObservers[vmID] = nil

        guard let session = sessions.removeValue(forKey: vmID) else { return }

        VBMemoryLeakDebugAssertions.vb_objectShouldBeReleasedSoon(session)
        VBMemoryLeakDebugAssertions.vb_objectShouldBeReleasedSoon(session.controller)
    }

    private func presentMissingVirtualMachineAlert(for vm: VBVirtualMachine) {
        let alert = NSAlert()
        alert.messageText = "“\(vm.name)” Isn’t Available"
        alert.informativeText = "Its files at \(vm.bundleURL.deletingLastPathComponent().path(percentEncoded: false)) can’t be found. If they’re on an external drive, connect it and try again."
        alert.runModal()
    }

    public func recoverInstallation(for vm: VBVirtualMachine, library: VMLibraryController) {
        let alert = NSAlert()
        alert.messageText = "Finish Installation"
        alert.informativeText = "In order to start this virtual machine, its operating system needs to be installed. Would you like to install it now?"
        alert.addButton(withTitle: "Install")
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let choice = alert.runModal()

        switch choice {
        case .alertFirstButtonReturn:
            launchInstallWizard(restoringAt: vm.bundleURL, library: library)
        case .alertSecondButtonReturn:
            library.performMoveToTrash(for: vm)
        default:
            break
        }
    }

    public func launchInstallWizard(restoringAt restoreURL: URL? = nil, library: VMLibraryController) {
        openWindow(animationBehavior: .documentWindow) {
            VMInstallationWizard(library: library, restoringAt: restoreURL)
                .environmentObject(library)
        }
    }

    public func launchImportVirtualMachinePanel(library: VMLibraryController) {
        guard let url = NSOpenPanel.run(accepting: VMImporterRegistry.default.supportedFileTypes, directoryURL: Self.virtualBuddyLibraryURL, defaultDirectoryKey: "importVirtualMachine", prompt: "Import") else {
            return
        }

        open(fileURL: url, library: library)
    }

    /// VirtualBuddy's own library, if it uses the default location, which is where most imports come from.
    private static var virtualBuddyLibraryURL: URL? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "VirtualBuddy", directoryHint: .isDirectory)
        return url.isReadableDirectory ? url : nil
    }

    private func importVirtualMachine(from path: FilePath, using importer: any VMImporter, library: VMLibraryController) async {
        do {
            guard await confirmImport(using: importer) else {
                throw CancellationError()
            }

            logger.debug("Import authorized from \(importer.appName) - \(path)")

            var model = try await importer.importVirtualMachine(from: path, into: library)

            model.metadata.importedFromAppName = importer.appName

            try model.saveMetadata()

            library.reload()

            open(fileURL: model.bundleURL, library: library)
        } catch is CancellationError {
            logger.notice("Import cancelled")
        } catch {
            NSApp.presentError(error)
        }
    }

    private var importTask: Task<Void, Never>?

    private func beginImportVirtualMachine(from path: FilePath, using importer: any VMImporter, library: VMLibraryController) {
        importTask = Task {
            await importVirtualMachine(from: path, using: importer, library: library)
        }
    }

    func confirmImport(using importer: any VMImporter) async -> Bool {
        #if DEBUG
        guard !Self.testImportSkipConfirmation else { return true }
        #endif
        
        return await NSAlert
            .runConfirmationAlert(
                title: "Import From \(importer.appName)?",
                message: "Hypervisaur will attempt to import your virtual machine from \(importer.appName). All data from this virtual machine in \(importer.appName) will be copied into your Hypervisaur library. Would you like to proceed?",
                continueButtonTitle: "Import",
                cancelButtonTitle: "Cancel",
                continueButtonIsDefault: true
            )
    }
}

// MARK: - File Opening

@MainActor
public extension VirtualMachineSessionUIManager {
    func open(fileURL: URL, library: VMLibraryController) {
        do {
            let values = try fileURL.resourceValues(forKeys: [.contentTypeKey])

            switch values.contentType {
            case .none:
                return
            case .virtualBuddyVM:
                handleOpenVirtualMachineFile(fileURL, library: library, options: nil)
            case .virtualBuddySavedState:
                handleOpenSavedStateFile(fileURL, library: library)
            default:
                let path = FilePath(fileURL)

                if let importer = VMImporterRegistry.default.importer(for: path) {
                    beginImportVirtualMachine(from: path, using: importer, library: library)
                } else {
                    throw Failure("Unsupported file type \(values.contentType?.identifier ?? "?")")
                }
            }
        } catch {
            logger.error("Error loading virtual machine from file at \(fileURL.path, privacy: .public): \(error, privacy: .public)")
        }
    }
}

@MainActor
private extension VirtualMachineSessionUIManager {
    func handleOpenVirtualMachineFile(_ url: URL, library: VMLibraryController, options: VMSessionOptions?) {
        if let loadedVM = library.virtualMachines.first(where: { $0.bundleURL.path == url.path }) {
            launch(loadedVM, library: library, options: options)
        } else {
            do {
                let vm = try VBVirtualMachine(bundleURL: url)

                launch(vm, library: library, options: options)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    /// Saved states created by earlier versions can't be resumed safely, so they're only ever shown, never opened.
    func handleOpenSavedStateFile(_ url: URL, library: VMLibraryController) {
        SavedSessionPrompts.presentLegacySavedState(at: url)
    }
}

#if DEBUG
// MARK: - Import Testing (Debug)
@MainActor
extension VirtualMachineSessionUIManager {
    static let testImportSkipConfirmation = UserDefaults.standard.bool(forKey: "VBTestImportSkipConfirmation")
    static let testImportVMPath: FilePath? = UserDefaults.standard.string(forKey: "VBTestImport").flatMap { FilePath($0) }

    public func testImportVMIfEnabled(library: VMLibraryController) {
        guard let path = Self.testImportVMPath else { return }

        open(fileURL: path.url, library: library)
    }
}
#endif
