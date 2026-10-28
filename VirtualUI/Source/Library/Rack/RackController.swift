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

    private var poweredMachines: [VBVirtualMachine] {
        machines.filter { monitor.statuses[$0.id]?.isRunning == true }
    }

    private var memoryDrawn: UInt64 {
        poweredMachines.reduce(0) { $0 + (monitor.usage[$1.id]?.memory ?? 0) }
    }

    private var diskRate: Double {
        poweredMachines.reduce(0) { $0 + (monitor.usage[$1.id]?.disk ?? 0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            RackEar()

            HStack(spacing: 14) {
                lights

                display

                VStack(alignment: .leading, spacing: 8) {
                    memoryMeter
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
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    // MARK: Lights

    private var lights: some View {
        HStack(spacing: 2) {
            RackLabeledLight(legend: "PWR", signal: .steady(RackPalette.green))
                .help("The rack has power while Hypervisaur is open.")

            RackLabeledLight(legend: "RUN", signal: poweredMachines.isEmpty ? .off : .steady(RackPalette.green))
                .help(poweredMachines.isEmpty
                    ? Text("Lights up while any of the virtual machines is running.")
                    : Text("^[\(poweredMachines.count) virtual machine](inflect: true) running."))

            RackLabeledLight(legend: "DSK", signal: .disk(bytesPerSecond: diskRate))
                .help(diskRate >= RackLight.Signal.diskActivityThreshold
                    ? "Running virtual machines are reading and writing \(Int64(diskRate).formatted(.byteCount(style: .file))) a second between them."
                    : "Flickers while running virtual machines read from or write to disk.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unitSummary)
    }

    // MARK: Display

    private var unitSummary: String {
        String(AttributedString(localized: "^[\(machines.count) unit](inflect: true) · \(poweredMachines.count) powered").characters)
    }

    /// Like a unit's display, it's backlit while a virtual machine is running.
    private var display: some View {
        LCDPanel(isBacklit: !poweredMachines.isEmpty) {
            VStack(alignment: .leading, spacing: LCDMetrics.lineSpacing) {
                LCDLine(text: "HYPERVISAUR")
                LCDLine(text: unitSummary.uppercased())
            }
        }
        .frame(minWidth: 150, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unitSummary)
    }

    // MARK: Meters

    private var memoryMeter: some View {
        RackMeter(
            title: "Memory drawn",
            reading: "\(memoryDrawn.formatted(.byteCount(style: .memory, spellsOutZero: false))) of \(physicalMemory.formatted(.byteCount(style: .memory)))",
            fraction: poweredMachines.isEmpty ? nil : Double(memoryDrawn) / Double(max(physicalMemory, 1)),
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
