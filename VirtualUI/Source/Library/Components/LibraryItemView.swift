//
//  LibraryItemView.swift
//  VirtualUI
//
//  Created by Guilherme Rambo on 21/07/22.
//

import SwiftUI
import Combine
import VirtualCore

public extension EnvironmentValues {
    /// This is injected by reading from ``VBSettings``.
    /// When `true`, the screens of virtual machines that are off show their desktop picture when there's no saved screenshot.
    @Entry var virtualBuddyShowDesktopPictureThumbnails = false
}

/// This button style achieves a couple of things:
/// - Gives its label a `vbLibraryButtonPressed` environment value that can be used to react to button presses
/// - Fixes an annoying behavior common to all standard SwiftUI button styles where pressing the space bar
/// with one of its subviews in focus would trigger the button's action instead of entering a space in a text field, for example
struct VBLibraryItemButtonStyle: PrimitiveButtonStyle {

    @State private var isPressed = false

    /// The rectangle of the button's contents in the local coordinate space.
    @State private var rect: CGRect = .zero

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.vbLibraryButtonPressed, isPressed)
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: VBLibraryButtonSizePreferenceKey.self, value: proxy.size)
                }
            }
            .onPreferenceChange(VBLibraryButtonSizePreferenceKey.self) { rect = CGRect(origin: .zero, size: $0) }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
                /// Replicate standard button behavior where dragging outside the button cancels the click.
                isPressed = rect.contains(value.location)
            }.onEnded { _ in
                /// If the button is not currently pressed, then don't perform the action.
                guard isPressed else { return }

                configuration.trigger()

                isPressed = false
            })
    }

}

struct VBLibraryButtonSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension PrimitiveButtonStyle where Self == VBLibraryItemButtonStyle {
    static var vbLibraryItem: VBLibraryItemButtonStyle { VBLibraryItemButtonStyle() }
}

private struct VBLibraryItemButtonPressedEnvironmentKey: EnvironmentKey {
    static var defaultValue = false
}
private extension EnvironmentValues {
    var vbLibraryButtonPressed: VBLibraryItemButtonPressedEnvironmentKey.Value {
        get { self[VBLibraryItemButtonPressedEnvironmentKey.self] }
        set { self[VBLibraryItemButtonPressedEnvironmentKey.self] = newValue }
    }
}

/// A virtual machine in the library, drawn as a unit in a rack: lights for its power, agent and disk, a small screen,
/// a label with its name and system, a plate with its hardware, meters for what it's using and a power button.
@MainActor
struct LibraryItemView: View {
    static let height: CGFloat = 72

    @EnvironmentObject var library: VMLibraryController
    @EnvironmentObject var sessionManager: VirtualMachineSessionUIManager
    @ObservedObject var activity: VMActivity

    var vm: VBVirtualMachine
    @State var name: String

    @Environment(\.vbLibraryButtonPressed)
    private var isPressed

    @State private var isHovered = false

    var nameFieldFocus = BoolSubject()

    @State private var configurationVM: VBVirtualMachine?

    private var isVMBooted: Bool { library.bootedMachineIdentifiers.contains(vm.id) }

    private var hasOpenSession: Bool { sessionManager.session(for: vm) != nil }

    /// The session of the virtual machine while it runs without a window.
    private var backgroundSession: VirtualMachineSessionUI? {
        sessionManager.isRunningInBackground(vm) ? sessionManager.session(for: vm) : nil
    }

    private var isDuplicating: Bool { library.duplicatingMachineIdentifiers.contains(vm.id) }

    /// Copying a virtual machine that's in use would copy a moving target, so it has to be saved or shut down first.
    private var canDuplicate: Bool { !library.isExecuting(vm) && !isDuplicating }

    private var isHighlighted: Bool { library.recentlyDuplicatedMachineIdentifier == vm.id }

    private var status: VMActivityStatus { activity.status }

    private var usage: VMResourceUsage? { activity.usage }

    private var hardware: VBMacDevice { vm.configuration.hardware }

    var body: some View {
        HStack(spacing: 0) {
            RackEar()

            HStack(spacing: 14) {
                lights

                RackScreen(vm: vm, preview: sessionManager.session(for: vm)?.livePreview, isPoweredOn: status.isRunning)
                    .overlay {
                        if isDuplicating {
                            ProgressView()
                                .controlSize(.small)
                                .help("Duplicating…")
                        }
                    }

                labelStrip

                specificationPlate

                HStack(spacing: 12) {
                    processorMeter
                    memoryMeter
                }

                RackPowerButton(
                    isOn: status.isRunning,
                    canShutDown: canShutDown,
                    primaryAction: launch,
                    shutDown: shutDown
                )
            }
            .padding(.horizontal, 12)

            RackEar()
        }
        .frame(height: Self.height)
        .background { RackFaceplate() }
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(RackPalette.teal, lineWidth: 1.5)
                    .shadow(color: RackPalette.teal.opacity(0.6), radius: 6)
            }
        }
        .rackUnitShape()
        .brightness(isHovered ? 0.03 : 0)
        .scaleEffect(isPressed ? 0.995 : 1)
        .onHover { isHovered = $0 }
        .opacity(isDuplicating ? 0.75 : 1)
        .contextMenu { contextMenuItems }
        .sheet(item: $configurationVM) { configurationVM in
            LibraryVMConfigurationSheet(vm: configurationVM)
                .environmentObject(library)
                .environment(library.templatesController)
        }
        .task(id: vm.name) { self.name = vm.name }
        .animation(isPressed ? .linear(duration: 0) : .snappy, value: isPressed)
        .animation(.snappy, value: isHovered)
        .animation(.snappy, value: isHighlighted)
    }

    // MARK: Lights

    private var lights: some View {
        HStack(spacing: 2) {
            RackLabeledLight(legend: "PWR", signal: powerSignal)
                .help(powerHelp)

            agentLight

            RackLabeledLight(legend: "DSK", signal: diskSignal, seed: vm.uuid.hashValue)
                .help(diskHelp)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityStatus)
    }

    private var powerSignal: RackLight.Signal {
        switch status {
        case .poweredOff: .off
        case .saved: vm.savedSession?.isReady == false ? .blink(RackPalette.amber) : .steady(RackPalette.amber)
        case .starting, .saving, .restoring: .blink(RackPalette.green)
        case .running: .steady(RackPalette.green)
        case .paused: .pulse(RackPalette.amber)
        }
    }

    private var powerHelp: String {
        switch status {
        case .poweredOff: "Powered off."
        case .saved:
            vm.savedSession?.issue?.explanation ?? "Saved. Starting it continues where you left off."
        case .starting: "Starting."
        case .running: "Running."
        case .paused: "Paused."
        case .saving: "Saving."
        case .restoring: "Resuming."
        }
    }

    private var agentLight: some View {
        ControllerReader(id: vm.id, isRunning: status.isRunning) { controller in
            if let controller {
                let agent = RackAgentState(controller: controller)
                RackLabeledLight(legend: "AGT", signal: agent.signal)
                    .help(agent.help)
            } else {
                RackLabeledLight(legend: "AGT", signal: .off)
                    .help("Lights up once the Hypervisaur agent in the running virtual machine connects.")
            }
        }
    }

    private var diskSignal: RackLight.Signal { .disk(bytesPerSecond: usage?.disk) }

    private var diskHelp: String {
        guard let usage, usage.disk >= RackLight.Signal.diskActivityThreshold else {
            return "Flickers while the virtual machine reads from or writes to disk."
        }
        return "Reading and writing \(Int64(usage.disk).formatted(.byteCount(style: .file))) a second."
    }

    private var accessibilityStatus: String {
        ([powerHelp] + statusDetails).joined(separator: ", ")
    }

    // MARK: Label

    /// A character LCD whose backlight is on while the virtual machine runs, showing its name and, below, its system and state.
    private var labelStrip: some View {
        LCDPanel(isBacklit: status.isRunning) {
            VStack(alignment: .leading, spacing: LCDMetrics.lineSpacing) {
                EphemeralTextField($name, alignment: .leading, setFocus: nameFieldFocus) { name in
                    LCDLine(text: name)
                } editableContent: { name in
                    TextField("VM Name", text: name)
                        .onSubmit { rename(name.wrappedValue) }
                } validate: { name in
                    do {
                        try library.validateNewName(name, for: vm)
                        return true
                    } catch {
                        return false
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(LCDPalette.ink)
                .disabled(isVMBooted || isDuplicating)
                .help(name)

                systemLine
            }
        }
        .frame(minWidth: 150, maxWidth: .infinity)
        /// The display is light, so editing the name has to look right on it.
        .environment(\.colorScheme, .light)
    }

    private var systemLine: some View {
        ControllerReader(id: vm.id, isRunning: status.isRunning) { controller in
            systemLine(systemLineText(reportedSystem: controller.flatMap { $0.guestAgentInfo?.system ?? $0.virtualMachineModel.metadata.lastKnownSystem }))
        }
    }

    private func systemLine(_ text: String) -> some View {
        LCDLine(text: text.uppercased())
            .help(text)
    }

    private func systemLineText(reportedSystem: String?) -> String {
        let system = reportedSystem ?? vm.metadata.lastKnownSystem ?? vm.configuration.systemType.name
        return ([system] + statusDetails).joined(separator: " · ")
    }

    /// What the label says about the virtual machine's state, after its system.
    private var statusDetails: [String] {
        var details = [String]()

        if isDuplicating { details.append("Duplicating…") }

        switch status {
        case .starting: details.append("Starting")
        case .paused: details.append("Paused")
        case .saving: details.append("Saving")
        case .restoring: details.append("Resuming")
        case .saved:
            if let savedSession = vm.savedSession {
                if !savedSession.isReady {
                    details.append("Saved – Needs Attention")
                } else if let date = savedSession.date {
                    details.append("Saved \(date.formatted(.dateTime.day().month().hour().minute()))")
                } else {
                    details.append("Saved")
                }
            }
        case .poweredOff, .running:
            break
        }

        if status.isRunning, sessionManager.isRunningInBackground(vm) { details.append("No Window") }
        if sessionManager.isKeptAwake(vm) { details.append("Kept Awake") }

        return details
    }

    // MARK: Plate and Meters

    private var specificationPlate: some View {
        HStack(spacing: 0) {
            plateCell("CPU", "\(hardware.cpuCount)")
                .help("\(hardware.cpuCount) processors assigned.")
            plateDivider
            plateCell("MEM", hardware.memorySize.formatted(.byteCount(style: .memory)))
                .help("\(hardware.memorySize.formatted(.byteCount(style: .memory))) of memory assigned.")
            plateDivider
            plateCell("DISK", activity.storage.map { $0.formatted(.byteCount(style: .file)) } ?? "–")
                .help("The space this virtual machine’s files take up on disk.")
            plateDivider
            plateCell("NET", networkLegend)
                .help(networkHelp)
        }
        .fixedSize()
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func plateCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(RackPalette.secondaryInk)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(RackPalette.ink)
                .monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var plateDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1)
    }

    private var networkLegend: String {
        switch hardware.networkDevices.first?.kind {
        case .NAT: "NAT"
        case .bridge: "BRDG"
        case nil: "NONE"
        }
    }

    private var networkHelp: String {
        switch hardware.networkDevices.first?.kind {
        case .NAT: "Shares the Mac’s network connection."
        case .bridge: "Joins the Mac’s network as a computer of its own."
        case nil: "Has no network connection."
        }
    }

    /// While a running virtual machine is first being measured, its meters say so rather than showing nothing.
    private var unmeasuredReading: String { status.isRunning ? "…" : "–" }

    private var processorMeter: some View {
        RackMeter(
            title: "CPU",
            reading: usage.map { $0.processor.formatted(.percent.precision(.fractionLength(0))) } ?? unmeasuredReading,
            fraction: usage?.processor,
            segments: 14
        )
        .help("How much of its \(hardware.cpuCount) processors the virtual machine is using.")
    }

    private var memoryMeter: some View {
        RackMeter(
            title: "MEM",
            reading: usage.map { $0.memory.formatted(.byteCount(style: .memory)) } ?? unmeasuredReading,
            fraction: usage.map { min(Double($0.memory) / Double(max(hardware.memorySize, 1)), 1) },
            segments: 12
        )
        .help("The Mac’s memory that the virtual machine is using, of the \(hardware.memorySize.formatted(.byteCount(style: .memory))) it has assigned.")
    }

    // MARK: Actions

    /// Shutting down needs the session that runs the virtual machine.
    private var canShutDown: Bool {
        sessionManager.session(for: vm)?.controller.state.isRunning == true
    }

    private func launch() {
        guard !isDuplicating else { return }
        sessionManager.launchAndStart(vm, library: library)
    }

    private func shutDown() {
        guard let session = sessionManager.session(for: vm) else { return }
        Task { await session.shutDown() }
    }

    private func rename(_ newName: String) {
        guard newName != vm.name else { return }

        do {
            try library.rename(vm, to: name)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// SwiftUI keeps the last context menu it made for as long as the view is around, so nothing in it may hold on to
    /// the virtual machine's session, which would then outlive it. Its actions look the session up when they're chosen.
    @ViewBuilder
    private var contextMenuItems: some View {
        if let backgroundSession {
            backgroundSessionMenuItems(state: backgroundSession.controller.state, canSave: backgroundSession.controller.saveEligibility.isApplicable)

            Divider()
        }

        Button {
            guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
            sessionManager.launchInFullScreen(vm, library: library, on: screen)
        } label: {
            Label(fullScreenTitle, systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .disabled(isDuplicating)
        .help(fullScreenHelp)

        if !hasOpenSession {
            Button {
                sessionManager.launchInBackground(vm, library: library)
            } label: {
                Label(vm.savedSession != nil ? "Resume Without Window" : "Start Without Window", systemImage: "rectangle.dashed")
            }
            .disabled(isDuplicating)
            .help(vm.savedSession != nil
                ? "Resumes the virtual machine without opening its window. Open it from the library to show its window."
                : "Starts the virtual machine without opening its window. Open it from the library to show its window.")
        }

        Divider()

        Button {
            NSWorkspace.shared.selectFile(vm.bundleURL.path, inFileViewerRootedAtPath: vm.bundleURL.deletingLastPathComponent().path)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        Divider()

        Button {
            configurationVM = vm
        } label: {
            Text("Configure…")
        }
        .disabled(hasOpenSession || isDuplicating)

        Button {
            duplicate()
        } label: {
            Text("Duplicate")
        }
        .disabled(!canDuplicate)
        .help(duplicateHelp)

        Button {
            clone()
        } label: {
            Text("Clone")
        }
        .disabled(!canClone)
        .help(cloneHelp)

        Button {
            nameFieldFocus.send(true)
        } label: {
            Text("Rename")
        }
        .disabled(isVMBooted || isDuplicating)

        #if DEBUG
        Button {
            NSWorkspace.shared.open(vm.metadataDirectoryURL)
        } label: {
            Text("Open Data Folder…")
        }
        #endif

        if sessionManager.session(for: vm)?.controller.canForceStop == true {
            let sessionManager = sessionManager
            let vm = vm

            Divider()

            Button {
                Task { await sessionManager.session(for: vm)?.forceStopAfterConfirmation() }
            } label: {
                Text("Force Stop…")
            }
        }

        Divider()

        Button {
            Task {
                guard await MoveToTrashConfirmation.confirm(vm, library: library, from: NSApp.keyWindow) else { return }
                library.performMoveToTrash(for: vm)
            }
        } label: {
            Text("Move to Trash…")
        }
        .disabled(isVMBooted || isDuplicating)
    }

    /// What can be done from the library to a virtual machine that's running without a window.
    @ViewBuilder
    private func backgroundSessionMenuItems(state: VMState, canSave: Bool) -> some View {
        let sessionManager = sessionManager
        let library = library
        let vm = vm

        Button {
            sessionManager.launch(vm, library: library, options: nil)
        } label: {
            Text("Show Window")
        }

        Toggle("Prevent Sleep", isOn: Binding(
            get: { sessionManager.isKeptAwake(vm) },
            set: { keepsAwake in
                guard let session = sessionManager.session(for: vm) else { return }
                sessionManager.setKeepsAwake(keepsAwake, for: session)
            }
        ))

        if canSave {
            Button {
                Task { await sessionManager.session(for: vm)?.saveAndClose() }
            } label: {
                Text("Save & Close")
            }
            .disabled(!state.canSaveAndClose)
        }

        Button {
            Task { await sessionManager.session(for: vm)?.shutDown() }
        } label: {
            Text("Shut Down")
        }
        .disabled(!state.isRunning)
    }

    private var isRunning: Bool {
        sessionManager.session(for: vm).map { !$0.controller.canStart } ?? false
    }

    private var fullScreenTitle: String {
        if isRunning { return "Show in Full Screen" }
        return vm.savedSession != nil ? "Resume in Full Screen" : "Start in Full Screen"
    }

    private var fullScreenHelp: String {
        if isRunning { return "Shows the virtual machine full screen, in a space of its own." }
        if vm.savedSession != nil { return "Resumes the virtual machine full screen, in a space of its own." }
        return "Starts the virtual machine full screen, in a space of its own."
    }

    private var duplicateHelp: String {
        if library.isExecuting(vm) {
            "Use Save & Close or shut down the virtual machine to duplicate it."
        } else if vm.savedSession != nil {
            "To keep this point for later, duplicate the saved VM before resuming it. Resuming a copy continues that copy."
        } else {
            "Duplicate this virtual machine."
        }
    }

    private var canClone: Bool {
        guard !isDuplicating, case .success = library.cloneEligibility(of: vm) else { return false }
        return true
    }

    private var cloneHelp: String {
        if case .failure(let error) = library.cloneEligibility(of: vm) {
            error.localizedDescription
        } else {
            "Make a copy that can run at the same time as this virtual machine. The copy shares disk space with the original until either of them changes."
        }
    }

    private func clone() {
        Task {
            do {
                try await library.clone(vm)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func duplicate() {
        Task {
            do {
                try await library.duplicate(vm)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// Shows content that depends on the published state of a running virtual machine's controller, updating as it changes.
///
/// The controller is looked up each time the content is made and only observed weakly, so that a view that stays on screen
/// for a moment after the virtual machine stops, such as during an animation, doesn't keep its controller alive.
private struct ControllerReader<Content: View>: View {
    var id: VBVirtualMachine.ID
    /// Whether to look for a controller, which only running virtual machines have.
    var isRunning: Bool
    @ViewBuilder var content: (VMController?) -> Content

    @EnvironmentObject private var library: VMLibraryController
    @StateObject private var observer = WeakControllerObserver()

    private var controller: VMController? { isRunning ? library.activeController(for: id) : nil }

    var body: some View {
        content(controller)
            .onChange(of: controller.map(ObjectIdentifier.init), initial: true) {
                observer.observe(controller)
            }
    }
}

/// Passes on a controller's changes to the view that owns it, without keeping the controller alive.
@MainActor
private final class WeakControllerObserver: ObservableObject {
    private weak var controller: VMController?
    private var subscription: AnyCancellable?

    func observe(_ controller: VMController?) {
        guard controller !== self.controller else { return }

        self.controller = controller
        subscription = controller?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

/// Whether the Hypervisaur agent in a running virtual machine is connected, which shells, logs and copying files need.
private enum RackAgentState {
    /// The virtual machine has no agent that can connect, such as a macOS guest with its guest app turned off.
    case absent
    case waiting
    case connected
    /// Connected, but too old to copy files.
    case outdated

    @MainActor
    init(controller: VMController) {
        /// macOS guests run the agent as part of the guest app.
        if controller.virtualMachineModel.configuration.systemType == .mac {
            if controller.guestAgentInfo != nil {
                self = .connected
                return
            }
            switch controller.guestAppConnectionStatus {
            case .connected: self = .connected
            case .disconnected: self = .waiting
            case .disabled, .unknown, nil: self = .absent
            }
        } else {
            switch controller.guestAgentStatus {
            case .connected: self = .connected
            case .outdated: self = .outdated
            case .disconnected, nil: self = .waiting
            }
        }
    }

    var signal: RackLight.Signal {
        switch self {
        case .absent: .off
        case .waiting: .pulse(RackPalette.blue)
        case .connected: .steady(RackPalette.teal)
        case .outdated: .steady(RackPalette.amber)
        }
    }

    var help: String {
        switch self {
        case .absent: "This virtual machine has no Hypervisaur agent running, so Open Shell, Show Logs and copying files aren’t available."
        case .waiting: "Waiting for the Hypervisaur agent in the virtual machine to connect."
        case .connected: "The Hypervisaur agent is connected, so Open Shell, Show Logs and copying files work."
        case .outdated: "The Hypervisaur agent is connected, but copying files needs a newer agent."
        }
    }
}

/// The small screen on the front of a unit. It shows what's on the virtual machine's display while it runs, the screen
/// it was saved at while it's saved, and stays dark while it's off.
private struct RackScreen: View {
    static let size = CGSize(width: 96, height: 60)

    var vm: VBVirtualMachine
    var preview: VMLivePreview?
    var isPoweredOn: Bool

    @Environment(\.virtualBuddyShowDesktopPictureThumbnails)
    private var showDesktopPicture

    @State private var stillImage: NSImage?

    private struct StillImageSource: Hashable {
        var metadata: VBVirtualMachine.Metadata
        var savedSession: VBSavedSessionDescriptor?
        var showDesktopPicture: Bool
    }

    var body: some View {
        ZStack {
            Color.black

            if let preview {
                LivePicture(preview: preview) { still }
            } else {
                still
            }

            /// The reflection on the glass.
            LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.6))
                .allowsHitTesting(false)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(.black.opacity(0.7), lineWidth: 1)
        }
        .animation(.smooth(duration: 0.6), value: isPoweredOn)
        .task(id: StillImageSource(metadata: vm.metadata, savedSession: vm.savedSession, showDesktopPicture: showDesktopPicture)) {
            stillImage = vm.savedScreenshot ?? (showDesktopPicture ? vm.thumbnail : nil)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var still: some View {
        if let stillImage {
            Image(nsImage: stillImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.size.width, height: Self.size.height)
                .saturation(isPoweredOn ? 1 : 0.35)
                .brightness(isPoweredOn ? 0 : -0.3)
        } else {
            ZStack {
                if isPoweredOn {
                    RadialGradient(colors: [RackPalette.teal.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 56)
                }

                vm.configuration.systemType.icon
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.white.opacity(isPoweredOn ? 0.7 : 0.16))
            }
        }
    }

    private struct LivePicture<Fallback: View>: View {
        @ObservedObject var preview: VMLivePreview
        @ViewBuilder var fallback: () -> Fallback

        var body: some View {
            ZStack {
                if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: RackScreen.size.width, height: RackScreen.size.height)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                } else {
                    fallback()
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.6), value: preview.image.map { ObjectIdentifier($0) })
        }
    }
}

/// Presents ``VMConfigurationSheet`` for a VM that doesn't have an open session window,
/// saving the configuration directly to the VM's bundle when the user confirms.
private struct LibraryVMConfigurationSheet: View {

    @State private var vm: VBVirtualMachine
    @StateObject private var viewModel: VMConfigurationViewModel

    init(vm: VBVirtualMachine) {
        self._vm = State(initialValue: vm)
        self._viewModel = StateObject(wrappedValue: VMConfigurationViewModel(vm, context: .postInstall))
    }

    var body: some View {
        VMConfigurationSheet(configuration: Binding(
            get: { vm.configuration },
            set: { save($0) }
        ))
        .environmentObject(viewModel)
    }

    private func save(_ configuration: VBMacConfiguration) {
        vm.configuration = configuration

        do {
            try vm.saveMetadata()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension VMLibraryController {
    func performMoveToTrash(for vm: VBVirtualMachine) {
        Task {
            do {
                try await moveToTrash(vm)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

#if DEBUG
#Preview {
    LibraryView()
        .environmentObject(VMLibraryController.preview)
        .environmentObject(VirtualMachineSessionUIManager.shared)
}
#endif
