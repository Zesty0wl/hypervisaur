import SwiftUI
import VirtualCore

/// Introduces saving the state of a virtual machine and asks what closing it should do.
struct CloseChoiceSheet: View {
    struct Result {
        var choice: SessionCloseChoice
        var makeDefault: Bool
        /// Whether a virtual machine that keeps running is kept from going to sleep.
        var keepsAwake: Bool
    }

    /// The virtual machines this applies to. A single name when closing a window, several when quitting.
    var machines: [String]
    /// Whether saving is available. It isn't offered when it isn't, and isn't mentioned at all when it doesn't apply.
    var eligibility: SavedSessionEligibility
    var isQuitting: Bool
    var onFinish: (Result?) -> Void

    @State private var selection: SessionCloseChoice
    @State private var makeDefault = false
    @State private var keepsAwake: Bool

    init(machines: [String], eligibility: SavedSessionEligibility = .supported, isQuitting: Bool, keepsAwake: Bool = false, onFinish: @escaping (Result?) -> Void) {
        self.machines = machines
        self.eligibility = eligibility
        self.isQuitting = isQuitting
        self.onFinish = onFinish
        self._keepsAwake = State(initialValue: keepsAwake)

        /// Saving is recommended when it's available. Otherwise, the choice that leaves the virtual machine as it is comes first.
        let initialSelection: SessionCloseChoice = if eligibility.isSupported {
            .saveState
        } else if !isQuitting {
            .keepRunning
        } else {
            .shutDown
        }
        self._selection = State(initialValue: initialSelection)
    }

    /// Virtual machines can't keep running once the app has quit.
    private var offersKeepRunning: Bool { !isQuitting }

    private var subtitle: String {
        if isQuitting {
            if machines.count == 1, let name = machines.first {
                return "“\(name)” is running."
            }
            return "\(machines.count) virtual machines are running."
        } else {
            return "“\(machines.first ?? "")” is running."
        }
    }

    private var confirmTitle: String {
        switch selection {
        case .saveState: "Save State"
        case .keepRunning: "Keep Running"
        case .shutDown: "Shutdown"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Header(subtitle: Text(subtitle), introducesSaving: eligibility.isSupported)

            VStack(spacing: 10) {
                if eligibility.isApplicable {
                    ChoiceCard(
                        symbol: "tray.and.arrow.down.fill",
                        title: "Save State",
                        badge: eligibility.isSupported ? "Recommended" : nil,
                        detail: eligibility.isSupported
                            ? "Pick up exactly where you left off. Unsaved work is preserved, and starting again takes a few seconds."
                            : eligibility.explanationForUser ?? "",
                        isSelected: selection == .saveState
                    ) {
                        selection = .saveState
                    }
                    .disabled(!eligibility.isSupported)
                }

                if offersKeepRunning {
                    ChoiceCard(
                        symbol: "play.rectangle.fill",
                        title: "Keep Running",
                        badge: nil,
                        detail: "Close the window and leave the virtual machine running in the background. Open it from the library to show its window again.",
                        isSelected: selection == .keepRunning
                    ) {
                        selection = .keepRunning
                    }

                    if selection == .keepRunning {
                        Toggle(isOn: $keepsAwake) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Prevent sleep")
                                Text("Keeps the virtual machine and this Mac awake while it runs in the background. The Mac’s display can still turn off.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 54)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                ChoiceCard(
                    symbol: "power",
                    title: "Shutdown",
                    badge: nil,
                    detail: "Ask the guest to shut down normally. Next time, the virtual machine starts up from scratch.",
                    isSelected: selection == .shutDown
                ) {
                    selection = .shutDown
                }
            }
            .animation(.snappy, value: selection)

            Toggle(isOn: $makeDefault) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set as default")
                    Text("You can change it later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if eligibility.isSupported {
                Text("A saved state stays with the virtual machine on this Mac. Shared folders and network connections aren’t preserved, and a saved state may stop working after macOS, Hypervisaur or QEMU updates. To keep a particular state around, duplicate the saved virtual machine before resuming it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    onFinish(nil)
                }
                .keyboardShortcut(.cancelAction)
                .airGlassButtonStyle()

                Spacer()

                Button(confirmTitle) {
                    onFinish(Result(choice: selection, makeDefault: makeDefault, keepsAwake: keepsAwake))
                }
                .keyboardShortcut(.defaultAction)
                .airGlassButtonStyle(prominent: true)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 460)
    }

    private struct Header: View {
        var subtitle: Text
        /// Saving is only introduced when it can be chosen.
        var introducesSaving: Bool

        var body: some View {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: introducesSaving ? "tray.and.arrow.down.fill" : "macwindow")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text(introducesSaving ? "Close now. Continue later." : "Close the Window?")
                        .font(.title2.weight(.semibold))

                    subtitle
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ChoiceCard: View {
    var symbol: String
    var title: String
    var badge: String?
    var detail: String
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    @Environment(\.isEnabled) private var isEnabled

    var tint: Color { isSelected ? .accentColor : .secondary }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)

                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && !isSelected ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering = $0 }
    }
}

// MARK: - Presentation

/// Lets the view hosted in a sheet finish the sheet it's in.
private final class SheetFinishBox<Output> {
    var finish: ((Output?) -> Void)?
}

@MainActor
extension SavedSessionPrompts {
    /// Presents a SwiftUI view as a sheet on the window, or in a window of its own when there's no window to attach to.
    /// - Returns: What the view finished with. Closing the view without finishing returns `nil`.
    static func presentSheet<Output, Content: View>(
        from window: NSWindow?,
        @ViewBuilder content: (_ finish: @escaping (Output?) -> Void) -> Content
    ) async -> Output? {
        await withCheckedContinuation { continuation in
            let box = SheetFinishBox<Output>()
            let hosting = NSHostingController(rootView: content { box.finish?($0) })
            hosting.sizingOptions = [.preferredContentSize]

            let sheetWindow = NSWindow(contentViewController: hosting)
            sheetWindow.styleMask = [.titled, .fullSizeContentView]
            sheetWindow.titlebarAppearsTransparent = true
            sheetWindow.isReleasedWhenClosed = false

            let parent = window.flatMap { $0.isVisible ? $0 : nil }

            var isFinished = false

            box.finish = { output in
                guard !isFinished else { return }
                isFinished = true
                box.finish = nil

                if let parent {
                    parent.endSheet(sheetWindow)
                }
                sheetWindow.orderOut(nil)
                sheetWindow.contentViewController = nil

                continuation.resume(returning: output)
            }

            if let parent {
                parent.beginSheet(sheetWindow)
            } else {
                sheetWindow.level = .floating
                sheetWindow.center()
                sheetWindow.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }
}

#if DEBUG
#Preview("Close") {
    CloseChoiceSheet(machines: ["macOS 27 Hackable"], isQuitting: false) { _ in }
}

#Preview("Close Keeping It Running") {
    CloseChoiceSheet(machines: ["Ubuntu"], eligibility: SavedSessionEligibility(issues: [.unsupportedGuest]), isQuitting: false, keepsAwake: true) { _ in }
}

#Preview("Close Without Saving") {
    CloseChoiceSheet(machines: ["macOS 27 Hackable"], eligibility: SavedSessionEligibility(issues: [.usbDeviceAttached]), isQuitting: false) { _ in }
}

#Preview("Close Linux") {
    CloseChoiceSheet(machines: ["Ubuntu"], eligibility: SavedSessionEligibility(issues: [.unsupportedGuest]), isQuitting: false) { _ in }
}

#Preview("Quit") {
    CloseChoiceSheet(machines: ["macOS 27 Hackable", "Sequoia Test"], isQuitting: true) { _ in }
}
#endif
