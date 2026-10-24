import SwiftUI
import VirtualCore
import OSLog

private let logger = Logger(subsystem: VirtualUIConstants.subsystemName, category: "VirtualMachineGuest")

extension VirtualMachineSessionUI {
    /// Opens a shell in the guest in the user's terminal app, through `hvctl`.
    ///
    /// The terminal runs a command file that removes itself, so that opening it doesn't need permission to control the terminal app.
    @MainActor
    func openShell() {
        do {
            let toolURL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/hvctl")
            guard FileManager.default.isExecutableFile(atPath: toolURL.path) else {
                throw Failure("Hypervisaur’s hvctl tool is missing from the app.")
            }

            let fileURL = FileManager.default.temporaryDirectory.appending(path: "Shell in \(virtualMachine.name) \(UUID().uuidString.prefix(8)).command")
            let script = """
            #!/bin/sh
            rm -f "$0"
            printf '\\033]0;%s\\007' \(shellQuoted("\(virtualMachine.name) Shell"))
            exec \(shellQuoted(toolURL.path)) shell \(shellQuoted(virtualMachine.name))

            """
            try Data(script.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.path)

            guard NSWorkspace.shared.open(fileURL) else {
                try? FileManager.default.removeItem(at: fileURL)
                throw Failure("There’s no app for opening the shell, such as Terminal.")
            }
        } catch {
            presentGuestError(error, doing: "Couldn’t Open a Shell")
        }
    }

    /// Opens a window that follows the guest's logs.
    @MainActor
    func showLogs() {
        let model = virtualMachine
        OpenCocoaWindowAction.default(id: "logs-\(model.id)") {
            GuestLogsView(virtualMachine: model)
        }
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    private func presentGuestError(_ error: Error, doing title: String) {
        logger.error("\(title, privacy: .public): \(error, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")

        if let hostWindow {
            alert.beginSheetModal(for: hostWindow)
        } else {
            alert.runModal()
        }
    }
}
