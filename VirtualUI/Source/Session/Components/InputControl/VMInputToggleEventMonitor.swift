import AppKit

/// Feeds the events of a window to a ``VMInputToggleHoldRecognizer``, for views that display a virtual machine.
///
/// The shortcuts must be recognized even when the view is not the first responder, which is the case when
/// keyboard events are not being delivered to the guest, so the events are observed before they're dispatched.
@MainActor
final class VMInputToggleEventMonitor {
    var handler: ((VMInputToggleHoldEvent) -> Void)? {
        didSet {
            recognizer.handler = handler
            update()
        }
    }

    private let recognizer = VMInputToggleHoldRecognizer()
    private weak var window: NSWindow?
    private var eventMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?

    /// Call when the view moves to a window, and with `nil` when it's about to leave its window.
    func setWindow(_ window: NSWindow?) {
        if window !== self.window {
            stop()
        }

        self.window = window

        update()
    }

    private func update() {
        let shouldMonitor = window != nil && handler != nil

        guard shouldMonitor != (eventMonitor != nil) else { return }

        if shouldMonitor {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.observe(event)
            return event
        }

        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recognizer.reset() }
        }
    }

    private func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }

        recognizer.reset()
    }

    private func observe(_ event: NSEvent) {
        guard let window, event.window === window, window.isKeyWindow else { return }

        switch event.type {
        case .flagsChanged:
            /// Modifier keys pressed while a mouse button is down are part of a click or drag in the guest.
            recognizer.modifiersChanged(to: NSEvent.pressedMouseButtons == 0 ? event.modifierFlags : [])
        default:
            /// Any other key or mouse button means the modifier keys are being held down for something else.
            recognizer.interrupt()
        }
    }
}
