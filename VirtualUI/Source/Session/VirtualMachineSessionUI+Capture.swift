import SwiftUI
import VirtualCore
import OSLog
import Combine

private let logger = Logger(subsystem: VirtualUIConstants.subsystemName, category: "VirtualMachineCapture")

/// A recording of a virtual machine's display that's in progress.
struct VMScreenRecording {
    let recorder: VMScreenRecorder
    let startDate: Date
}

extension VirtualMachineSessionUI {
    /// The virtual machine while it's running, which is when its display can be captured.
    @MainActor
    var displayedRuntime: VMRuntime? {
        guard case .running(let runtime) = controller.state else { return nil }
        return runtime
    }

    @MainActor
    var canCapture: Bool { displayedRuntime != nil }

    @MainActor
    var captureRegion: VMCaptureRegion? {
        displayView.flatMap(VMCaptureRegion.init(view:))
    }

    // MARK: - Screenshots

    /// A screenshot of the virtual machine's display.
    @MainActor
    public func screenshot() async throws -> CGImage {
        guard let runtime = displayedRuntime else {
            throw Failure("“\(virtualMachine.name)” isn’t running.")
        }

        return try await VMScreenCapture.screenshot(of: runtime, in: captureRegion)
    }

    /// Saves a screenshot of the virtual machine's display where macOS saves screenshots.
    @MainActor
    func takeScreenshot() async {
        guard !isTakingScreenshot else { return }

        isTakingScreenshot = true
        defer { isTakingScreenshot = false }

        do {
            let image = try await screenshot()
            let url = VMCaptureLocation.newFileURL(for: virtualMachine, pathExtension: "png")
            try await VMScreenCapture.writePNG(image, to: url)

            logger.info("Saved screenshot to \(url.path, privacy: .public)")
            NSSound(named: "Grab")?.play()
            capturedFileSaved.send(url)
        } catch {
            presentCaptureError(error, doing: "Couldn’t Take a Screenshot")
        }
    }

    // MARK: - Recording

    @MainActor
    func toggleRecording() async {
        if recording != nil {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    @MainActor
    func startRecording() async {
        guard recording == nil else { return }

        do {
            guard canCapture else {
                throw Failure("“\(virtualMachine.name)” isn’t running.")
            }
            guard let region = captureRegion else {
                throw Failure("The virtual machine’s display isn’t on screen.")
            }

            let url = VMCaptureLocation.newFileURL(for: virtualMachine, pathExtension: "mov")
            let recorder = try await VMScreenRecorder.start(capturing: region, to: url)

            recorder.onStop = { [weak self] error in
                guard let self, self.recording?.recorder === recorder else { return }
                self.recording = nil
                self.observeDisplayViewFrame(false)

                if let error {
                    self.presentCaptureError(error, doing: "The Recording Stopped")
                } else {
                    self.capturedFileSaved.send(recorder.url)
                }
            }

            recording = VMScreenRecording(recorder: recorder, startDate: .now)
            observeDisplayViewFrame(true)
        } catch {
            presentCaptureError(error, doing: "Couldn’t Start Recording")
        }
    }

    @MainActor
    func stopRecording() async {
        guard let recording else { return }

        self.recording = nil
        observeDisplayViewFrame(false)

        do {
            let url = try await recording.recorder.stop()
            capturedFileSaved.send(url)
        } catch {
            presentCaptureError(error, doing: "Couldn’t Save the Recording")
        }
    }

    /// Keeps the recording on the display while the window is resized.
    @MainActor
    private func observeDisplayViewFrame(_ observe: Bool) {
        displayViewFrameObserver = nil

        guard observe, let displayView else { return }

        displayView.postsFrameChangedNotifications = true
        displayViewFrameObserver = NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: displayView)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let recorder = self.recording?.recorder, let region = self.captureRegion else { return }
                    Task { await recorder.update(region) }
                }
            }
    }

    // MARK: - Errors

    @MainActor
    private func presentCaptureError(_ error: Error, doing title: String) {
        logger.error("\(title, privacy: .public): \(error, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription

        let needsPermission = error is ScreenCapturePermissionError
        if needsPermission {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }

        let handleResponse = { (response: NSApplication.ModalResponse) in
            guard needsPermission, response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(ScreenCapturePermissionError.settingsURL)
        }

        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}
