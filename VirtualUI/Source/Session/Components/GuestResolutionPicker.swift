import SwiftUI
import VirtualCore

/// The resolutions a Windows guest can be switched to, for the Guest menu and the window's toolbar, since Windows' own
/// settings don't offer them with the virtio GPU's driver. The one Windows is using is checked.
struct GuestResolutionPicker: View {
    var modes: GuestDisplayModes
    var isSwitching: Bool
    var switchTo: (GuestDisplayResolution) -> Void

    var body: some View {
        Picker("Resolution", selection: selection) {
            ForEach(modes.available.reversed(), id: \.self) { resolution in
                Text(resolution.title)
                    .tag(Optional(resolution))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(isSwitching)
    }

    private var selection: Binding<GuestDisplayResolution?> {
        Binding {
            modes.current
        } set: { resolution in
            guard let resolution, resolution != modes.current else { return }
            switchTo(resolution)
        }
    }
}

/// A toolbar menu that switches a Windows guest to another resolution, while it can be switched.
struct VirtualMachineResolutionControl: View {
    @ObservedObject var controller: VMController

    var body: some View {
        if let modes = controller.guestDisplayModes, !modes.available.isEmpty {
            Menu {
                GuestResolutionPicker(modes: modes, isSwitching: controller.isSwitchingGuestResolution) { [weak controller] resolution in
                    controller?.switchGuestResolutionPresentingErrors(to: resolution)
                }
            } label: {
                Label("Resolution", systemImage: "display")
                    .labelStyle(.iconOnly)
            }
            .help(modes.current.map { "Change the resolution of Windows, which is \($0.title)" } ?? "Change the resolution of Windows")
        }
    }
}

extension GuestDisplayResolution {
    var title: String { "\(width) × \(height)" }
}

extension VMController {
    /// Switches the guest to another resolution, and says why when it can't.
    func switchGuestResolutionPresentingErrors(to resolution: GuestDisplayResolution) {
        Task {
            do {
                try await switchGuestResolution(to: resolution)
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}
