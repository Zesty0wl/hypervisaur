import SwiftUI

extension View {
    /// Performs the action with whether any part of the window that contains the view is visible on screen,
    /// once the view is in a window and whenever that changes.
    func onWindowVisibilityChange(perform action: @escaping (Bool) -> Void) -> some View {
        background { WindowVisibilityReader(action: action) }
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    var action: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {
        nsView.action = action
    }
}

private final class WindowVisibilityView: NSView {
    var action: ((Bool) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionStateDidChange), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }

        /// Moving to a window happens while SwiftUI updates the view hierarchy, which mustn't change state.
        DispatchQueue.main.async { [weak self] in
            self?.reportVisibility()
        }
    }

    @objc private func occlusionStateDidChange(_ notification: Notification) {
        reportVisibility()
    }

    private func reportVisibility() {
        action?(window?.occlusionState.contains(.visible) == true)
    }
}
