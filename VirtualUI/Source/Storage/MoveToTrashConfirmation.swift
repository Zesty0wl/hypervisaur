import SwiftUI
import VirtualCore

/// Asks before moving a virtual machine to the Trash, saying how much space that frees, since copies of a virtual machine
/// share its storage and deleting one of them only frees what's its own.
@MainActor
enum MoveToTrashConfirmation {
    static func confirm(_ vm: VBVirtualMachine, library: VMLibraryController, from window: NSWindow?) async -> Bool {
        let inputs = library.virtualMachines.map(VMStorageAnalyzer.Input.init)
        let analyzer = VMStorageAnalyzer(libraryURL: library.libraryURL, downloadsURL: nil)
        let report = await Task.detached(priority: .userInitiated) { analyzer.analyze(inputs) }.value

        let alert = NSAlert()
        alert.messageText = "Move “\(vm.name)” to the Trash?"
        alert.informativeText = report.machine(withID: vm.id).map { explanation(for: $0, in: report) }
            ?? "Its space is freed once you empty the Trash."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        return await alert.present(from: window) == .alertFirstButtonReturn
    }

    private static func explanation(for machine: VMStorageReport.Machine, in report: VMStorageReport) -> String {
        let freed = "This frees about \(machine.freedIfDeleted.formattedBytes) once you empty the Trash."

        /// Sharing a few blocks of metadata doesn't matter to anyone.
        guard machine.sharedSize > 1 << 20 else { return freed }

        let names = report.relatives(of: machine).map { "“\($0.name)”" } + report.trashedRelatives(of: machine).map { "“\($0.name)” in the Trash" }
        let shared = machine.sharedSize.formattedBytes

        if names.isEmpty {
            return "\(freed) The other \(shared) is shared with other files on the volume, outside the library, and is only freed once they’re deleted too."
        }

        return "\(freed) The other \(shared) is shared with \(names.formatted(.list(type: .and))), and is only freed once \(names.count == 1 ? "that’s" : "they’re") deleted too."
    }
}
