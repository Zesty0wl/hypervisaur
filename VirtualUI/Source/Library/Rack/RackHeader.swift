import SwiftUI
import VirtualCore

/// The strip across the top of the rack, saying how many of its units are powered and how much of the Mac's memory
/// they're drawing between them.
struct RackHeader: View {
    var machines: [VBVirtualMachine]
    @ObservedObject var monitor: VMActivityMonitor

    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    private var poweredMachines: [VBVirtualMachine] {
        machines.filter { monitor.statuses[$0.id]?.isRunning == true }
    }

    private var memoryDrawn: UInt64 {
        poweredMachines.reduce(0) { $0 + (monitor.usage[$1.id]?.memory ?? 0) }
    }

    var body: some View {
        HStack(alignment: .bottom) {
            Text("^[\(machines.count) unit](inflect: true) · \(poweredMachines.count) powered")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(RackPalette.secondaryInk)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 16)

            RackMeter(
                title: "Memory drawn",
                reading: "\(memoryDrawn.formatted(.byteCount(style: .memory, spellsOutZero: false))) of \(physicalMemory.formatted(.byteCount(style: .memory)))",
                fraction: poweredMachines.isEmpty ? nil : Double(memoryDrawn) / Double(max(physicalMemory, 1)),
                segments: 32
            )
            .help("The Mac’s memory that running virtual machines are using between them.")
        }
        .padding(.horizontal, RackRails.width + 8)
        .padding(.bottom, 8)
    }
}
