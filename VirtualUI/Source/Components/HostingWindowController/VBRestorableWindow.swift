//
//  VBRestorableWindow.swift
//  VirtualUI
//
//  Created by Guilherme Rambo on 09/03/23.
//

import Cocoa

class VBRestorableWindow: FB18383725Window {

    override func close() {
        vbSaveFrame()

        super.close()
    }

    private var savedFrameKey: String? {
        guard let identifier, let screen else { return nil }
        guard let screenNumber = screen.deviceDescription[.init("NSScreenNumber")] as? Int else { return nil }

        return "window-\(identifier.rawValue)-\(screenNumber)"
    }

    /// The size of the window's content when it opens without a saved frame that can be used, such as the size of a
    /// virtual machine's display. It's scaled down to fit the screen.
    var preferredContentSize: CGSize?

    /// The width of the window's content as it was last chosen, when the window opened, was resized from the menu, or was
    /// resized by hand. When the window keeps the proportions of a display that changes resolution, it goes back to this
    /// width whenever the screen has room, rather than staying narrower after proportions that had to be fitted to the screen.
    var chosenContentWidth: CGFloat?

    private var liveResizeObserver: Any?

    private var savedFrame: NSRect? {
        guard let savedFrameKey else { return nil }
        guard let dict = UserDefaults.standard.dictionary(forKey: savedFrameKey) else { return nil }
        return NSRect(dictionaryRepresentation: dict as CFDictionary)
    }

    /// A saved frame is only used if it's mostly on a screen that's still connected, and, for windows with a preferred size,
    /// if it's at least half that size, so that a window that once ended up tiny doesn't keep opening that way.
    private var usableSavedFrame: NSRect? {
        guard let savedFrame else { return nil }

        if let preferredContentSize {
            let contentSize = contentRect(forFrameRect: savedFrame).size
            guard contentSize.width >= preferredContentSize.width / 2, contentSize.height >= preferredContentSize.height / 2 else { return nil }
        }

        let isOnScreen = NSScreen.screens.contains { screen in
            let visibleArea = screen.visibleFrame.intersection(savedFrame)
            return visibleArea.width * visibleArea.height >= savedFrame.width * savedFrame.height / 2
        }
        return isOnScreen ? savedFrame : nil
    }

    private var applicationWillTerminateObserver: Any?

    override func makeKey() {
        super.makeKey()

        if applicationWillTerminateObserver == nil {
            applicationWillTerminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.vbSaveFrame()
            })
        }
    }

    /// Windows are placed when they're first shown, at their saved frame, or at their preferred size in the middle of the screen.
    override func center() {
        if let usableSavedFrame {
            setFrame(usableSavedFrame, display: true)
        } else if let preferredContentSize, let screen = screen ?? NSScreen.main {
            setFrame(preferredFrame(forContentSize: preferredContentSize, on: screen), display: true)
        } else {
            super.center()
        }

        chosenContentWidth = contentRect(forFrameRect: frame).width

        if liveResizeObserver == nil {
            liveResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.chosenContentWidth = self.contentRect(forFrameRect: self.frame).width
            }
        }
    }

    /// Room around the window is left on the screen, so that it doesn't look maximized.
    private static let preferredScreenFraction: CGFloat = 0.85

    private func preferredFrame(forContentSize contentSize: CGSize, on screen: NSScreen) -> NSRect {
        let chromeSize = frameRect(forContentRect: .zero).size
        let availableSize = CGSize(
            width: screen.visibleFrame.width * Self.preferredScreenFraction - chromeSize.width,
            height: screen.visibleFrame.height * Self.preferredScreenFraction - chromeSize.height
        )
        let scale = min(1, availableSize.width / contentSize.width, availableSize.height / contentSize.height)

        var frame = frameRect(forContentRect: NSRect(
            x: 0,
            y: 0,
            width: (contentSize.width * scale).rounded(),
            height: (contentSize.height * scale).rounded()
        ))
        frame.origin = CGPoint(
            x: (screen.visibleFrame.midX - frame.width / 2).rounded(),
            y: (screen.visibleFrame.midY - frame.height / 2).rounded()
        )
        return frame
    }

    private func vbSaveFrame() {
        guard let savedFrameKey else { return }
        UserDefaults.standard.set(frame.dictionaryRepresentation, forKey: savedFrameKey)
        UserDefaults.standard.synchronize()
    }

    private var frameConstraintsDisabled = false

    func withFrameConstraintsDisabled(_ disabled: Bool = true, perform block: () -> Void) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(resetConstraintsDisabledFlag), object: nil)

        frameConstraintsDisabled = disabled

        block()

        perform(#selector(resetConstraintsDisabledFlag), with: nil, afterDelay: 0.2)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard frameConstraintsDisabled else {
            return super.constrainFrameRect(frameRect, to: screen)
        }

        return frameRect
    }

    @objc private func resetConstraintsDisabledFlag() {
        frameConstraintsDisabled = false
    }

}
