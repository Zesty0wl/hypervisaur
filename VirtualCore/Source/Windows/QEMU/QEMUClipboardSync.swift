import AppKit

/// Shares text between the Mac's clipboard and the guest's, through the virtual machine's display connection.
///
/// The Mac's clipboard has no notification for changes, so it's checked every second while the virtual machine runs.
@MainActor
final class QEMUClipboardSync {
    private static let pollInterval = Duration.seconds(1)

    private let display: VNCClient
    private let pasteboard: NSPasteboard
    private var pollTask: Task<Void, Never>?

    /// The Mac's clipboard as of the last time it was shared with the guest, or written with what the guest copied.
    private var changeCount: Int

    /// Whether something was copied in the guest after the Mac's clipboard was last shared with it.
    /// Until then, the guest's clipboard is left alone when the Mac's text is offered again.
    private var guestHasNewerClipboard = false

    init(display: VNCClient, pasteboard: NSPasteboard = .general) {
        self.display = display
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount

        display.onGuestClipboardChange = { [weak self] in
            self?.guestHasNewerClipboard = true
        }
        display.onGuestClipboardText = { [weak self] text in
            self?.write(text)
        }
    }

    func start() {
        shareHostText()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                self.shareHostTextIfChanged()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Shares the Mac's text with the guest again, unless something was copied in the guest since it was last shared.
    ///
    /// The guest's agent doesn't receive what was on the clipboard before it started, so this is how text that was
    /// copied before then is shared, such as when the virtual machine's window becomes active.
    func offerHostText() {
        guard !guestHasNewerClipboard else { return }
        shareHostText()
    }

    private func shareHostTextIfChanged() {
        guard pasteboard.changeCount != changeCount else { return }
        shareHostText()
    }

    private func shareHostText() {
        changeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string), display.announceClipboardText(text) else { return }
        guestHasNewerClipboard = false
    }

    private func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCount = pasteboard.changeCount
    }
}
