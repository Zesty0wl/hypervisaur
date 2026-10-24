import SwiftUI
import Cocoa
import Carbon.HIToolbox
import VirtualCore

/// Displays a virtual machine that runs with QEMU and sends it keyboard and mouse input.
struct QEMUDisplayView: NSViewRepresentable {
    typealias NSViewType = QEMUFramebufferView

    var machine: QEMUVirtualMachine
    let captureSystemKeysEnabled: Bool
    /// Called with the progress of the shortcuts that toggle input devices when held down.
    /// The shortcuts are only enabled when a handler is provided.
    var onInputToggleHold: ((VMInputToggleHoldEvent) -> Void)? = nil
    /// Called when the guest's display changes resolution, and with its resolution once the first frame arrives.
    var onDisplaySizeChange: ((CGSize) -> Void)? = nil

    func makeNSView(context: Context) -> QEMUFramebufferView {
        QEMUFramebufferView(frame: .zero)
    }

    func updateNSView(_ nsView: QEMUFramebufferView, context: Context) {
        nsView.machine = machine
        nsView.capturesSystemKeys = captureSystemKeysEnabled
        nsView.eventDeliveryMask = context.environment.virtualMachineEventDeliveryMask
        nsView.inputToggleHoldHandler = onInputToggleHold
        nsView.displaySizeHandler = onDisplaySizeChange
    }
}

final class QEMUFramebufferView: NSView {
    var machine: QEMUVirtualMachine? {
        didSet {
            guard machine !== oldValue else { return }

            if let frameObserver, let oldValue {
                oldValue.removeFrameObserver(frameObserver)
            }
            frameObserver = nil
            layer?.contents = nil

            observeFramesIfNeeded()
        }
    }

    var capturesSystemKeys = false

    var eventDeliveryMask = VMEventDeliveryMask.all {
        didSet {
            guard eventDeliveryMask != oldValue else { return }

            if !eventDeliveryMask.allowsKeyboardEvents {
                releasePressedKeys()
            }
            if !eventDeliveryMask.allowsMouseEvents {
                releasePressedButtons()
            }

            if oldValue.allowsKeyboardEvents != eventDeliveryMask.allowsKeyboardEvents {
                if eventDeliveryMask.allowsKeyboardEvents {
                    window?.makeFirstResponder(self)
                } else if window?.firstResponder === self {
                    window?.makeFirstResponder(nil)
                }
            }

            window?.invalidateCursorRects(for: self)
        }
    }

    var inputToggleHoldHandler: ((VMInputToggleHoldEvent) -> Void)? {
        get { inputToggleMonitor.handler }
        set { inputToggleMonitor.handler = newValue }
    }

    var displaySizeHandler: ((CGSize) -> Void)?

    private let inputToggleMonitor = VMInputToggleEventMonitor()
    private var frameObserver: UUID?
    private var framebufferSize = CGSize.zero

    private var pressedKeys = Set<UInt32>()
    private var pressedButtons = VNCClient.PointerButtons()
    private var lastPointerLocation: (x: Int, y: Int)?
    private var scrollAccumulator = CGPoint.zero

    /// The guest draws its own pointer, so the host's is hidden while it's over the guest's display.
    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Display

    override var isOpaque: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    /// Frames are only observed while the view is in a window, which also ensures the observer goes away with the view.
    private func observeFramesIfNeeded() {
        guard window != nil, frameObserver == nil, let machine else { return }

        frameObserver = machine.addFrameObserver { [weak self] frame in
            self?.display(frame)
        }
    }

    private func stopObservingFrames() {
        guard let frameObserver else { return }

        machine?.removeFrameObserver(frameObserver)
        self.frameObserver = nil
    }

    private func display(_ frame: CGImage) {
        let size = CGSize(width: frame.width, height: frame.height)
        if size != framebufferSize {
            framebufferSize = size
            window?.invalidateCursorRects(for: self)
            displaySizeHandler?(size)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = frame
        CATransaction.commit()
    }

    /// The area of the view that the guest's display occupies, matching the aspect fit of the layer's contents.
    private var displayRect: CGRect {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return bounds }

        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let size = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)

        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    override func resetCursorRects() {
        guard eventDeliveryMask.allowsMouseEvents, machine != nil else { return }
        addCursorRect(displayRect, cursor: Self.invisibleCursor)
    }

    // MARK: - Window

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        inputToggleMonitor.setWindow(nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)

        if newWindow == nil {
            stopObservingFrames()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        inputToggleMonitor.setWindow(window)

        guard let window else { return }

        observeFramesIfNeeded()

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)

        if eventDeliveryMask.allowsKeyboardEvents {
            window.makeFirstResponder(self)
        }
    }

    /// Text copied on the Mac before the guest's clipboard agent started can be pasted once the window is back in use.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        machine?.offerClipboardToGuest()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        releasePressedKeys()
        releasePressedButtons()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for area in trackingAreas {
            removeTrackingArea(area)
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { eventDeliveryMask.allowsKeyboardEvents }

    override func resignFirstResponder() -> Bool {
        releasePressedKeys()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard eventDeliveryMask.allowsKeyboardEvents else { return }

        /// The guest repeats keys that are held down by itself.
        guard !event.isARepeat else { return }

        sendKey(for: event.keyCode, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        guard eventDeliveryMask.allowsKeyboardEvents else { return }

        sendKey(for: event.keyCode, isDown: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturesSystemKeys,
              eventDeliveryMask.allowsKeyboardEvents,
              window?.firstResponder === self,
              event.type == .keyDown
        else { return super.performKeyEquivalent(with: event) }

        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard eventDeliveryMask.allowsKeyboardEvents else { return }

        /// Caps lock reports its state rather than whether the key is down, the guest toggles it on each press.
        if Int(event.keyCode) == kVK_CapsLock {
            sendKey(for: event.keyCode, isDown: true)
            sendKey(for: event.keyCode, isDown: false)
            return
        }

        guard let deviceFlag = Self.deviceModifierFlags[Int(event.keyCode)] else { return }

        let isDown = (event.modifierFlags.rawValue & deviceFlag) != 0
        sendKey(for: event.keyCode, isDown: isDown)
    }

    /// Device-dependent modifier flags from IOKit, which tell the left and right keys apart.
    private static let deviceModifierFlags: [Int: UInt] = [
        kVK_Control: 0x0001,
        kVK_Shift: 0x0002,
        kVK_RightShift: 0x0004,
        kVK_Command: 0x0008,
        kVK_RightCommand: 0x0010,
        kVK_Option: 0x0020,
        kVK_RightOption: 0x0040,
        kVK_RightControl: 0x2000,
    ]

    private func sendKey(for keyCode: UInt16, isDown: Bool) {
        guard let machine, let keyNumber = QEMUKeyMap.keyNumber(forKeyCode: keyCode) else { return }

        if isDown {
            pressedKeys.insert(keyNumber)
        } else {
            guard pressedKeys.remove(keyNumber) != nil else { return }
        }

        machine.sendKey(keyNumber, isDown: isDown)
    }

    private func releasePressedKeys() {
        guard let machine else {
            pressedKeys.removeAll()
            return
        }

        for keyNumber in pressedKeys {
            machine.sendKey(keyNumber, isDown: false)
        }
        pressedKeys.removeAll()
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { eventDeliveryMask.allowsMouseEvents }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard eventDeliveryMask.allowsMouseEvents else { return nil }
        return super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(for: event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(for: event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(for: event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(for: event) }

    override func mouseDown(with event: NSEvent) {
        if eventDeliveryMask.allowsKeyboardEvents { window?.makeFirstResponder(self) }
        updateButton(.left, isDown: true, event: event)
    }

    override func mouseUp(with event: NSEvent) { updateButton(.left, isDown: false, event: event) }
    override func rightMouseDown(with event: NSEvent) { updateButton(.right, isDown: true, event: event) }
    override func rightMouseUp(with event: NSEvent) { updateButton(.right, isDown: false, event: event) }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        updateButton(.middle, isDown: true, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        updateButton(.middle, isDown: false, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard eventDeliveryMask.allowsMouseEvents, let machine else { return }

        sendPointer(for: event)

        /// Precise deltas from trackpads are in points, which are grouped into wheel detents for the guest.
        let pointsPerDetent: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1

        if event.phase == .began || event.momentumPhase == .began {
            scrollAccumulator = .zero
        }

        scrollAccumulator.x += event.scrollingDeltaX / pointsPerDetent
        scrollAccumulator.y += event.scrollingDeltaY / pointsPerDetent

        let verticalDetents = Int(scrollAccumulator.y.rounded(.towardZero))
        let horizontalDetents = Int(scrollAccumulator.x.rounded(.towardZero))
        scrollAccumulator.y -= CGFloat(verticalDetents)
        scrollAccumulator.x -= CGFloat(horizontalDetents)

        guard let location = lastPointerLocation else { return }

        func click(_ button: VNCClient.PointerButtons, times: Int) {
            for _ in 0..<min(abs(times), 32) {
                machine.sendPointer(x: location.x, y: location.y, buttons: pressedButtons.union(button))
                machine.sendPointer(x: location.x, y: location.y, buttons: pressedButtons)
            }
        }

        click(verticalDetents > 0 ? .wheelUp : .wheelDown, times: verticalDetents)
        click(horizontalDetents > 0 ? .wheelLeft : .wheelRight, times: horizontalDetents)
    }

    private func updateButton(_ button: VNCClient.PointerButtons, isDown: Bool, event: NSEvent) {
        guard eventDeliveryMask.allowsMouseEvents else { return }

        if isDown {
            pressedButtons.insert(button)
        } else {
            pressedButtons.remove(button)
        }

        sendPointer(for: event)
    }

    private func sendPointer(for event: NSEvent) {
        guard eventDeliveryMask.allowsMouseEvents, let machine, framebufferSize.width > 0, framebufferSize.height > 0 else { return }

        let point = convert(event.locationInWindow, from: nil)
        let rect = displayRect

        let normalizedX = (point.x - rect.minX) / rect.width
        let normalizedY = 1 - (point.y - rect.minY) / rect.height

        let x = Int((normalizedX * framebufferSize.width).rounded(.down))
        let y = Int((normalizedY * framebufferSize.height).rounded(.down))

        lastPointerLocation = (x, y)

        machine.sendPointer(x: x, y: y, buttons: pressedButtons)
    }

    private func releasePressedButtons() {
        guard !pressedButtons.isEmpty else { return }

        pressedButtons = []

        if let machine, let location = lastPointerLocation {
            machine.sendPointer(x: location.x, y: location.y, buttons: [])
        }
    }
}
