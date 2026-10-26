import SwiftUI
import VirtualCore

/// A recent, small picture of a running virtual machine's display, which the library shows in place of its artwork.
///
/// Previews only live in memory, for as long as the virtual machine runs. Guests that run in QEMU can always be captured.
/// Guests that run with Virtualization are captured from their window, so their preview stays as it was while they run
/// in the background, and they don't get one until Hypervisaur is allowed to record the screen.
final class VMLivePreview: ObservableObject {
    /// How often previews are taken again while the library is on screen.
    static let refreshInterval = Duration.seconds(30)

    @Published fileprivate(set) var image: CGImage?
}

extension VirtualMachineSessionUI {
    /// Takes a new preview of the virtual machine's display. When it can't be captured right now, the previous preview stays.
    @MainActor
    func refreshPreview() async {
        guard let runtime = displayedRuntime else { return }

        guard let image = await VMScreenCapture.preview(of: runtime, in: captureRegion) else { return }

        /// The virtual machine may have stopped while the preview was being taken.
        guard displayedRuntime != nil else { return }

        livePreview.image = image
    }

    /// Forgets the preview once the virtual machine's display has gone away.
    @MainActor
    func clearPreview() {
        livePreview.image = nil
    }
}
