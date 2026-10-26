import SwiftUI
import VirtualCore
import ManagedPreferencesUI
import Combine
import AVFoundation

public final class VirtualMachineSessionUI: ObservableObject {

    public enum WindowSize: Int {
        case pointAccurate
        case pixelAccurate
        case fitScreen
    }

    @Published public var lockProportions = false

    /// The resolution of the guest's display while it runs, unless the display follows the size of the window.
    /// The window keeps the same proportions as the display, so that it isn't surrounded by black bars.
    @Published private(set) var fixedGuestDisplaySize: CGSize?

    @Published private(set) var eventDeliveryMask = VMEventDeliveryMask.all

    @Published var captureMouseEvents = true
    @Published var captureKeyboardEvents = true

    /// Presents the HUD that tells the user when an input device is connected or disconnected,
    /// and about the shortcut that can be held down to do so.
    let inputStatusHUD: VMInputStatusHUDPresenter

    /// Holds on to the current aspect ratio, so that a window that opens for a virtual machine that's already running gets it too.
    let setWindowAspectRatio = CurrentValueSubject<CGSize?, Never>(nil)
    let resizeWindow = PassthroughSubject<WindowSize, Never>()
    let makeWindowKey = PassthroughSubject<Void, Never>()

    public let controller: VMController
    public let virtualMachine: VBVirtualMachine

    /// What the session is waiting for while the window stays open, when that isn't visible in the controller state.
    @Published private(set) var activity: SessionActivity?

    /// The window that presents this session. Alerts are presented as sheets on it.
    weak var hostWindow: NSWindow?

    /// The view that the virtual machine's display fills, which is what screenshots and recordings capture.
    weak var displayView: NSView?

    /// The recording of the virtual machine's display that's in progress.
    @Published var recording: VMScreenRecording?

    /// Whether a screenshot is being taken, which takes a moment for guests that are captured from their window.
    @Published var isTakingScreenshot = false

    /// Copies files dropped on the window to the guest, and files dragged out of the guest to the Mac.
    @MainActor private(set) lazy var fileTransfers = GuestFileTransferCenter(controller: controller)

    /// Keeps the virtual machine awake while it runs in the background, when the user asks for it.
    @MainActor private(set) lazy var sleepPrevention = VMSleepPrevention(controller: controller)

    /// What the virtual machine's display shows, for the library.
    let livePreview: VMLivePreview

    /// Sent with each screenshot or recording once it's saved.
    let capturedFileSaved = PassthroughSubject<URL, Never>()

    /// Follows the display while it's recorded. See `observeDisplayViewFrame(_:)`.
    var displayViewFrameObserver: AnyCancellable?

    /// Decides what closing the session involves. Repeated requests to close join the one that's already in progress.
    private(set) var closer: SessionCloseCoordinator!
    private var prompts: SessionAlertPrompts!

    private var cancellables = Set<AnyCancellable>()

    @MainActor
    public convenience init(with virtualMachine: VBVirtualMachine, library: VMLibraryController, options: VMSessionOptions?) {
        self.init(controller: VMController(with: virtualMachine, library: library, options: options))
    }

    @MainActor
    public init(controller: VMController) {
        self.controller = controller
        self.virtualMachine = controller.virtualMachineModel
        self.inputStatusHUD = VMInputStatusHUDPresenter()
        self.livePreview = VMLivePreview()

        self.prompts = SessionAlertPrompts(ui: self)
        self.closer = SessionCloseCoordinator(controller: controller, prompts: prompts)

        $lockProportions.combineLatest($fixedGuestDisplaySize)
            .dropFirst()
            .map { [weak self] lockProportions, fixedGuestDisplaySize -> CGSize? in
                if let fixedGuestDisplaySize { return fixedGuestDisplaySize }

                guard lockProportions, let display = self?.virtualMachine.configuration.hardware.displayDevices.first else { return nil }
                return CGSize(width: display.width, height: display.height)
            }
            .removeDuplicates()
            .sink { [weak self] ratio in
                self?.setWindowAspectRatio.send(ratio)
            }
            .store(in: &cancellables)

        $captureMouseEvents.sink { [weak self] captureMouse in
            if captureMouse {
                self?.eventDeliveryMask.insert(.mouse)
            } else {
                self?.eventDeliveryMask.remove(.mouse)
            }
        }
        .store(in: &cancellables)

        $captureKeyboardEvents.sink { [weak self] captureKeyboard in
            if captureKeyboard {
                self?.eventDeliveryMask.insert(.keyboard)
            } else {
                self?.eventDeliveryMask.remove(.keyboard)
            }
        }
        .store(in: &cancellables)

        $captureMouseEvents.dropFirst().removeDuplicates().sink { [weak self] captureMouse in
            self?.inputStatusHUD.statusChanged(for: .pointingDevice, isConnected: captureMouse)
        }
        .store(in: &cancellables)

        $captureKeyboardEvents.dropFirst().removeDuplicates().sink { [weak self] captureKeyboard in
            self?.inputStatusHUD.statusChanged(for: .keyboard, isConnected: captureKeyboard)
        }
        .store(in: &cancellables)

        /// A recording ends with the virtual machine's display, and the window is free to take any shape.
        controller.$state.map(ShownDisplay.init).removeDuplicates().sink { [weak self] display in
            guard let self else { return }

            guard display != .none else {
                self.fixedGuestDisplaySize = nil
                self.clearPreview()

                if self.recording != nil {
                    Task { await self.stopRecording() }
                }
                return
            }

            /// Virtualization keeps the display at its configured size, unless it's set to follow the window. QEMU reports
            /// the guest's resolution from its frames instead, since Windows can change it.
            if display == .virtualization,
               let device = self.virtualMachine.configuration.hardware.displayDevices.first,
               !device.automaticallyReconfiguresDisplay
            {
                self.fixedGuestDisplaySize = CGSize(width: device.width, height: device.height)
            }
        }
        .store(in: &cancellables)
    }

    /// Responds to the user holding down the shortcut that toggles an input device.
    @MainActor
    func handleInputToggleHold(_ event: VMInputToggleHoldEvent) {
        switch event {
        case .began(let device, let remaining):
            inputStatusHUD.holdBegan(
                for: device,
                isConnected: eventDeliveryMask.contains(device.deliveryMask),
                remaining: remaining
            )
        case .cancelled:
            inputStatusHUD.holdCancelled()
        case .completed(let device):
            switch device {
            case .keyboard: captureKeyboardEvents.toggle()
            case .pointingDevice: captureMouseEvents.toggle()
            }
        }
    }

    @MainActor
    public func update(with newOptions: VMSessionOptions?) {
        guard let newOptions else { return }

        if newOptions != controller.options {
            /// If we're trying to launch a virtual machine with custom options and those don't match the current options,
            /// we must ensure that the VM is not currently running/paused, otherwise changing the options won't have any effect.
            /// If the VM is currently not in a state where options can be changed, then the user will be prompted to shut it down before doing so.
            guard controller.canStart else {
                let alert = NSAlert()
                alert.messageText = "Virtual Machine Already in Use"
                alert.informativeText = "\"\(virtualMachine.name)\" is already in use. Please shut down the virtual machine before starting it with the new options."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        }

        /// The VM is currently in a state where it's safe to change the options, just update the options for the controller.
        controller.options = newOptions

        /// This takes care of booting when the session is already open and a deep link that wants auto-boot is activated.
        if newOptions.autoBoot, controller.canStart {
            Task { await startOrResume() }
        }
    }

    /// Which kind of virtual machine's display is shown, which is while it runs or is paused.
    private enum ShownDisplay {
        case none
        case virtualization
        case qemu

        init(_ state: VMState) {
            switch state {
            case .running(.virtualization), .paused(.virtualization): self = .virtualization
            case .running(.qemu), .paused(.qemu): self = .qemu
            default: self = .none
            }
        }
    }

    /// Called with each new resolution of a guest display that doesn't follow the size of the window.
    @MainActor
    func fixedGuestDisplaySizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        fixedGuestDisplaySize = size
    }

    @MainActor
    func setActivity(_ activity: SessionActivity?) {
        self.activity = activity
    }

    @MainActor
    public func bringToFront() {
        makeWindowKey.send()
    }

    deinit {
        VBMemoryLeakDebugAssertions.vb_objectIsBeingReleased(self)
    }
}

public struct VirtualMachineWindowCommands: View {
    @EnvironmentObject private var manager: VirtualMachineSessionUIManager

    @State private var focusedSessionReference: WeakReference<VirtualMachineSessionUI>?
    private var focusedSession: VirtualMachineSessionUI? { focusedSessionReference?.object }

    @AppStorage("vm.window.proportions.locked")
    private var lockProportions = false

    public init() { }

    public var body: some View {
        Group {
            Toggle("Lock Proportions", isOn: $lockProportions)

            Button("Point Accurate") {
                focusedSession?.resizeWindow.send(.pointAccurate)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Pixel Accurate") {
                focusedSession?.resizeWindow.send(.pixelAccurate)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Fit Screen") {
                focusedSession?.resizeWindow.send(.fitScreen)
            }
            .keyboardShortcut("3", modifiers: .command)
        }
        .disabled(focusedSession == nil)
        .onReceive(manager.focusedSessionChanged) { ref in
            focusedSessionReference = ref
            ref?.object?.lockProportions = lockProportions
        }
        .onChange(of: lockProportions) { _, newValue in
            focusedSession?.lockProportions = newValue
        }

        Divider()
    }

}

public struct VirtualMachineGuestCommands: View {
    @EnvironmentObject private var manager: VirtualMachineSessionUIManager

    @State private var focusedSessionReference: WeakReference<VirtualMachineSessionUI>?
    private var focusedSession: VirtualMachineSessionUI? { focusedSessionReference?.object }

    public init() { }

    public var body: some View {
        Group {
            if let session = focusedSession {
                VirtualMachineGuestActions(session: session)
                    .id(ObjectIdentifier(session.controller))
            } else {
                /// Dummy item for when session is not available.
                Button {
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
            }
        }
        .disabled(focusedSession == nil)
        .onReceive(manager.focusedSessionChanged) { ref in
            focusedSessionReference = ref
        }
    }
}

@MainActor
private final class WeakVMControllerObserver: ObservableObject {
    private(set) weak var controller: VMController?

    private var cancellable: AnyCancellable?

    init(controller: VMController) {
        self.controller = controller
        self.cancellable = controller.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }
}

private struct VirtualMachineGuestActions: View {
    /// Commands are installed in the app-wide main menu and may outlive the session window.
    /// This observer forwards updates without retaining the VM controller.
    @StateObject private var observer: WeakVMControllerObserver

    @State private var actionTask: Task<Void, Never>?

    private var controller: VMController? { observer.controller }

    /// Held weakly for the same reason as the controller.
    private let sessionReference: WeakReference<VirtualMachineSessionUI>
    private var session: VirtualMachineSessionUI? { sessionReference.object }

    init(session: VirtualMachineSessionUI) {
        sessionReference = WeakReference(session)
        _observer = StateObject(wrappedValue: WeakVMControllerObserver(controller: session.controller))
    }

    var body: some View {
        Group {
            if controller?.state.isRunning == true {
                stopButton
                    .modifier { button in
                        if #available(macOS 15.0, *) {
                            button.modifierKeyAlternate(.option) {
                                forceStopButton
                            }
                        } else {
                            button
                        }
                    }
            } else {
                Button { [observer] in
                    runGuestAction {
                        guard let controller = observer.controller else { return }

                        if controller.canResume {
                            try await controller.resume()
                        } else {
                            await session?.startOrResume()
                        }
                    }
                } label: {
                    Label(controller?.state.isSaved == true ? "Resume" : "Start", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actionTask != nil || !((controller?.canStart == true) || (controller?.canResume == true)))
            }

            Button { [observer] in
                runGuestAction {
                    guard let controller = observer.controller else { return }
                    try await controller.pause()
                }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(actionTask != nil || controller?.canPause != true)

            if controller?.saveEligibility.isApplicable != false {
                Button {
                    runGuestAction {
                        await session?.saveAndClose()
                    }
                } label: {
                    Label("Save & Close", systemImage: "tray.and.arrow.down.fill")
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(actionTask != nil || controller?.state.canSaveAndClose != true)
            }

            Button {
                runGuestAction {
                    await session?.runInBackground()
                }
            } label: {
                Label("Run in Background", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(actionTask != nil || session?.canRunInBackground != true)

            /// Available even while another action is in progress, since a stuck one is when it's needed.
            Button {
                Task { await session?.forceStopAfterConfirmation() }
            } label: {
                Label("Force Stop…", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".", modifiers: [.command, .option])
            .disabled(controller?.canForceStop != true)

            Divider()

            Button {
                session?.openShell()
            } label: {
                Label("Open Shell", systemImage: "terminal")
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(controller?.state.isRunning != true)

            Button {
                session?.showLogs()
            } label: {
                Label("Show Logs", systemImage: "list.bullet.rectangle")
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(controller?.state.isRunning != true)

            Divider()

            VirtualMachineNetworkCommands(observer: observer)

            if #available(macOS 27.0, *) {
                VirtualMachineUSBCommands(observer: observer)
            }
        }
    }

    private var stopButton: some View {
        Button { [observer] in
            runGuestAction {
                guard let controller = observer.controller else { return }
                try await controller.stop()
            }
        } label: {
            Label("Shut Down", systemImage: "power")
        }
        .disabled(actionTask != nil)
    }

    /// Available even while another action is in progress, since a stuck one is when it's needed.
    private var forceStopButton: some View {
        Button {
            Task { await session?.forceStopAfterConfirmation() }
        } label: {
            Label("Force Stop…", systemImage: "stop.circle.fill")
        }
        .disabled(controller?.canForceStop != true)
    }

    private func runGuestAction(_ action: @escaping @MainActor () async throws -> Void) {
        actionTask = Task { @MainActor in
            defer { actionTask = nil }

            do {
                try await action()
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}

private struct VirtualMachineNetworkCommands: View {
    @ManagedValue(for: .disableBridgedNetworking, schema: VirtualBuddyManagedPreferences.schema, default: false)
    private var bridgedNetworkingDisabled: Bool

    @ObservedObject var observer: WeakVMControllerObserver

    private var controller: VMController? { observer.controller }

    var body: some View {
        Menu {
            Button { [observer] in
                performNetworkAction {
                    guard let controller = observer.controller else { return }
                    try controller.reconnectNetwork()
                }
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .disabled(controller?.canReconnectNetwork != true)

            Divider()

            if bridgedNetworkingDisabled {
                Text("Bridged networking is disabled by your organization.")
            }

            let availableInterfaces = controller?.availableBridgeInterfaces ?? []

            if availableInterfaces.isEmpty {
                Button {
                } label: {
                    Label("No Host Interfaces Available", systemImage: "network.slash")
                }
                .disabled(true)
            } else {
                ForEach(availableInterfaces) { interface in
                    Button { [observer] in
                        performNetworkAction {
                            guard let controller = observer.controller else { return }
                            try controller.changeBridgeInterface(to: interface.id)
                        }
                    } label: {
                        Label(
                            interfaceDisplayName(interface),
                            systemImage: isActive(interface) ? "checkmark" : "network"
                        )
                    }
                    .disabled(bridgedNetworkingDisabled || controller?.canChangeBridgeInterface != true || isActive(interface))
                }
            }
        } label: {
            Label("Network", systemImage: "network")
        }
    }

    private func isActive(_ interface: VBNetworkDeviceInterface) -> Bool {
        controller?.activeBridgeInterfaceIdentifiers == [interface.id]
    }

    private func interfaceDisplayName(_ interface: VBNetworkDeviceInterface) -> String {
        guard interface.name != interface.id else { return interface.name }
        return "\(interface.name) (\(interface.id))"
    }

    private func performNetworkAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            NSApp.presentError(error)
        }
    }
}

@available(macOS 27.0, *)
private struct VirtualMachineUSBCommands: View {
    @ManagedValue(for: .disableUSBPassthrough, schema: VirtualBuddyManagedPreferences.schema, default: false)
    private var usbPassthroughDisabled: Bool

    @ObservedObject var observer: WeakVMControllerObserver

    @State private var actionDeviceID: VMUSBDeviceController.Device.ID?

    private var controller: VMController? { observer.controller }
    private var deviceController: VMUSBDeviceController? { controller?.usbDeviceController }
    private var isGuestActive: Bool {
        controller?.state.isRunning == true || controller?.state.isPaused == true
    }

    var body: some View {
        Menu {
            if usbPassthroughDisabled {
                Text("USB passthrough is disabled by your organization.")
            }
            if let registrationErrorMessage = deviceController?.registrationErrorMessage {
                Button {
                } label: {
                    Label("USB Access Unavailable", systemImage: "exclamationmark.triangle")
                }
                .disabled(true)
                .help(registrationErrorMessage)
            } else if let devices = deviceController?.devices, !devices.isEmpty {
                ForEach(devices) { device in
                    Button {
                        toggleAttachment(for: device)
                    } label: {
                        Label {
                            if let productName = device.productName {
                                Text(productName)
                            } else {
                                Text("USB Device")
                            }
                        } icon: {
                            Image(systemName: device.isAttached ? "checkmark" : "cable.connector")
                        }
                    }
                    .disabled(actionDeviceID != nil || device.isBusy || (usbPassthroughDisabled && !device.isAttached))
                    .help(device.errorMessage ?? usbIdentifierDescription(for: device))
                }
            } else {
                Button {
                } label: {
                    Label("No USB Devices Available", systemImage: "cable.connector.slash")
                }
                .disabled(true)

                Button {
                } label: {
                    Text("Grant access from the menu bar")
                }
                .disabled(true)
            }
        } label: {
            Label("USB Devices", systemImage: "cable.connector")
        }
        .disabled(!isGuestActive || deviceController == nil)
    }

    private func toggleAttachment(for device: VMUSBDeviceController.Device) {
        guard let deviceController else { return }

        actionDeviceID = device.id

        Task { @MainActor in
            defer { actionDeviceID = nil }

            do {
                try await deviceController.toggleAttachment(for: device.id)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    private func usbIdentifierDescription(for device: VMUSBDeviceController.Device) -> String {
        String(
            format: "Vendor 0x%04X, Product 0x%04X",
            device.vendorID,
            device.productID
        )
    }
}
