import SwiftUI
import VirtualCore

/// The unit at the top of the rack that looks after the others: lights for the rack as a whole, a display saying how many
/// units it holds and how many are powered, meters for the Mac's memory and the library's storage, and a key for adding a unit.
struct RackController: View {
    var machines: [VBVirtualMachine]
    @ObservedObject var monitor: VMActivityMonitor
    var showStorage: () -> Void
    var addMachine: () -> Void

    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    /// The meters are the same width, so that they line up.
    private static let meterSegments = 28
    private static let meterSegmentHeight: CGFloat = 9

    /// What the rack shows about its units, worked out once each time it changes.
    private struct Totals {
        var powered: Int
        var memoryDrawn: UInt64
        var diskRate: Double
        /// How many units the rack holds and how many are powered, as the display says it.
        var summary: String

        @MainActor
        init(machines: [VBVirtualMachine], monitor: VMActivityMonitor) {
            let poweredMachines = machines.filter { monitor.statuses[$0.id]?.isRunning == true }

            powered = poweredMachines.count
            memoryDrawn = poweredMachines.reduce(0) { $0 + (monitor.usage[$1.id]?.memory ?? 0) }
            diskRate = poweredMachines.reduce(0) { $0 + (monitor.usage[$1.id]?.disk ?? 0) }
            summary = String(AttributedString(localized: "^[\(machines.count) unit](inflect: true) · \(powered) powered").characters)
        }
    }

    var body: some View {
        let totals = Totals(machines: machines, monitor: monitor)

        HStack(spacing: 0) {
            RackEar()

            HStack(spacing: 14) {
                lights(totals)

                display(totals)

                VStack(alignment: .leading, spacing: 8) {
                    memoryMeter(totals)
                    storageMeter
                }

                HStack(spacing: 8) {
                    Button(action: showStorage) {
                        Image(systemName: "internaldrive")
                    }
                    .buttonStyle(RackKeyButtonStyle(legend: "DISK"))
                    .help("Show how virtual machines use storage (⌥⌘0).")
                    .accessibilityLabel("Storage")

                    Button(action: addMachine) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(RackKeyButtonStyle(legend: "NEW"))
                    .help("Create a new virtual machine (⌘N).")
                    .accessibilityLabel("New Virtual Machine")
                }
            }
            .padding(.horizontal, 12)

            RackEar()
        }
        .frame(height: LibraryItemView.height)
        .background { RackFaceplate() }
        .rackUnitShape()
    }

    // MARK: Lights

    private func lights(_ totals: Totals) -> some View {
        HStack(spacing: 2) {
            RackLabeledLight(legend: "PWR", signal: .steady(RackPalette.green))
                .help("The rack has power while Hypervisaur is open.")

            RackLabeledLight(legend: "RUN", signal: totals.powered == 0 ? .off : .steady(RackPalette.green))
                .help(totals.powered == 0
                    ? Text("Lights up while any of the virtual machines is running.")
                    : Text("^[\(totals.powered) virtual machine](inflect: true) running."))

            RackLabeledLight(legend: "DSK", signal: .disk(bytesPerSecond: totals.diskRate))
                .help(totals.diskRate >= RackLight.Signal.diskActivityThreshold
                    ? "Running virtual machines are reading and writing \(Int64(totals.diskRate).formatted(.byteCount(style: .file))) a second between them."
                    : "Flickers while running virtual machines read from or write to disk.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(totals.summary)
    }

    // MARK: Display

    /// Like a unit's display, it's backlit while a virtual machine is running.
    private func display(_ totals: Totals) -> some View {
        LCDPanel(isBacklit: totals.powered > 0) {
            VStack(alignment: .leading, spacing: LCDMetrics.lineSpacing) {
                LCDLine(text: "HYPERVISAUR")
                LCDLine(text: totals.summary.uppercased())
            }
        }
        .frame(minWidth: 150, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(totals.summary)
    }

    // MARK: Meters

    private func memoryMeter(_ totals: Totals) -> some View {
        RackMeter(
            title: "Memory drawn",
            reading: "\(totals.memoryDrawn.formatted(.byteCount(style: .memory, spellsOutZero: false))) of \(physicalMemory.formatted(.byteCount(style: .memory)))",
            fraction: totals.powered == 0 ? nil : Double(totals.memoryDrawn) / Double(max(physicalMemory, 1)),
            segments: Self.meterSegments,
            segmentHeight: Self.meterSegmentHeight
        )
        .help("The Mac’s memory that running virtual machines are using between them.")
    }

    private var storageMeter: some View {
        let volume = monitor.libraryVolume

        return Button(action: showStorage) {
            RackMeter(
                title: "Storage",
                reading: volume.map { "\($0.availableCapacity.formatted(.byteCount(style: .file))) free of \($0.capacity.formatted(.byteCount(style: .file)))" } ?? "–",
                fraction: volume.map { Double($0.usedCapacity) / Double(max($0.capacity, 1)) },
                segments: Self.meterSegments,
                segmentHeight: Self.meterSegmentHeight,
                showsDisclosure: true
            )
        }
        .buttonStyle(RackPanelButtonStyle())
        .help(volume.map { "The library is on “\($0.name)”, which has \($0.availableCapacity.formatted(.byteCount(style: .file))) available of \($0.capacity.formatted(.byteCount(style: .file))). Click to see how virtual machines use it." }
            ?? "Click to see how virtual machines use the library’s storage.")
        .accessibilityLabel("Storage")
    }
}
