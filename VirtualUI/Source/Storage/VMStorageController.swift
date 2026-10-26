import SwiftUI
import VirtualCore
import Combine

/// Measures how the library uses storage for ``StorageView``, away from the main actor.
@MainActor
final class VMStorageController: ObservableObject {
    /// How often the measurements are taken again while they're on screen. Running virtual machines keep writing to their disks.
    static let refreshInterval = Duration.seconds(30)

    @Published private(set) var report: VMStorageReport?
    @Published private(set) var isMeasuring = false

    private let library: VMLibraryController?
    private var measuringTask: Task<Void, Never>?
    private var libraryObservation: AnyCancellable?

    init(library: VMLibraryController) {
        self.library = library

        /// Virtual machines that are added, removed or renamed are measured right away.
        libraryObservation = library.$virtualMachines
            .dropFirst()
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    /// Shows a report that's already been made, for previews.
    init(report: VMStorageReport) {
        self.library = nil
        self.report = report
    }

    /// Measures everything again, unless that's already happening.
    func refresh() {
        guard let library, measuringTask == nil else { return }

        let inputs = library.virtualMachines.map(VMStorageAnalyzer.Input.init)
        let analyzer = VMStorageAnalyzer(libraryURL: library.libraryURL, downloadsURL: VBSettings.current.downloadsDirectoryURL)

        isMeasuring = true

        measuringTask = Task { [weak self] in
            let report = await Task.detached(priority: .utility) { analyzer.analyze(inputs) }.value

            guard let self else { return }
            self.report = report
            self.isMeasuring = false
            self.measuringTask = nil
        }
    }

    /// Keeps the measurements up to date until the task that calls this is cancelled.
    func observe() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// The library's virtual machine that a measured one is, for what's known about it now, such as whether it's running.
    func virtualMachine(for machine: VMStorageReport.Machine) -> VBVirtualMachine? {
        library?.virtualMachines.first { $0.id == machine.id }
    }

    func isRunning(_ machine: VMStorageReport.Machine) -> Bool {
        library?.bootedMachineIdentifiers.contains(machine.id) == true
    }
}
