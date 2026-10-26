import SwiftUI
import VirtualCore

/// Shows whether a virtual machine in the library is running and, while it runs, how much of the Mac it's using.
struct LibraryItemActivityView: View {
    var vm: VBVirtualMachine
    @ObservedObject var monitor: VMActivityMonitor
    /// Whether the virtual machine is running without a window.
    var isInBackground = false
    /// Whether the virtual machine is kept from going to sleep while it runs in the background.
    var isKeptAwake = false

    private var status: VMActivityStatus { monitor.statuses[vm.id] ?? .poweredOff }

    private var usage: VMResourceUsage? { status.isRunning ? monitor.usage[vm.id] : nil }

    private var hardware: VBMacDevice { vm.configuration.hardware }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusLabel

                if isKeptAwake {
                    Image(systemName: "cup.and.saucer.fill")
                        .help("This virtual machine and the Mac are kept awake while it runs in the background.")
                        .accessibilityLabel("Prevents sleep")
                        .transition(.opacity)
                }

                Spacer(minLength: 0)

                if let storage = monitor.storage[vm.id] {
                    Label(storage.formatted(.byteCount(style: .file)), systemImage: "internaldrive")
                        .help("The space this virtual machine’s files take up on disk.")
                }
            }

            HStack(spacing: 12) {
                if let usage {
                    processor(usage)
                    memory(usage)
                } else if status.isRunning {
                    Text("Measuring…")
                } else {
                    Text("\(hardware.cpuCount) CPUs · \(hardware.memorySize.formatted(.byteCount(style: .memory))) memory")
                }

                Spacer(minLength: 0)
            }
            .frame(height: CPUSparkline.height)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .animation(.snappy, value: status)
        .animation(.snappy, value: isKeptAwake)
    }

    private var statusLabel: some View {
        Label {
            Text(isInBackground && status.isRunning ? "\(status.title) in Background" : status.title)
                .foregroundStyle(.primary)
                .fontWeight(.medium)
        } icon: {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.tint)
        }
        .contentTransition(.symbolEffect(.replace))
    }

    private func processor(_ usage: VMResourceUsage) -> some View {
        HStack(spacing: 5) {
            Text("CPU")
            CPUSparkline(values: usage.processorHistory)
            Text(usage.processor.formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.primary)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .help("How much of its \(hardware.cpuCount) processors the virtual machine is using, over the last minute.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processor use \(usage.processor.formatted(.percent.precision(.fractionLength(0))))")
    }

    private func memory(_ usage: VMResourceUsage) -> some View {
        HStack(spacing: 5) {
            Text("Memory")
            Text(usage.memory.formatted(.byteCount(style: .memory)))
                .foregroundStyle(.primary)
        }
        .help("The Mac’s memory that the virtual machine is using. It has \(hardware.memorySize.formatted(.byteCount(style: .memory))) assigned.")
        .accessibilityElement(children: .combine)
    }
}

/// Processor use over recent samples, on a fixed scale from none to all of the virtual machine's processors.
private struct CPUSparkline: View {
    static let height: CGFloat = 14
    static let width: CGFloat = 44

    var values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }

            let capacity = VMActivityMonitor.historyLength
            let step = size.width / CGFloat(capacity - 1)
            /// The line is inset so that its full width stays visible at the top and bottom of the scale.
            let lineWidth: CGFloat = 1.5
            let usableHeight = size.height - lineWidth
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: size.width - CGFloat(values.count - 1 - index) * step,
                    y: lineWidth / 2 + usableHeight * (1 - value)
                )
            }

            var line = Path()
            line.addLines(points)

            var area = line
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .color(.accentColor.opacity(0.2)))
            context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Self.width, height: Self.height)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

private extension VMActivityStatus {
    var title: String {
        switch self {
        case .poweredOff: "Powered Off"
        case .saved: "Saved"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .saving: "Saving"
        case .restoring: "Resuming"
        }
    }

    var symbolName: String {
        switch self {
        case .poweredOff: "power.circle"
        case .saved: "tray.full.fill"
        case .starting: "ellipsis.circle.fill"
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .saving: "tray.and.arrow.down.fill"
        case .restoring: "tray.and.arrow.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .poweredOff, .saved: .secondary
        case .starting, .saving, .restoring: .blue
        case .running: .green
        case .paused: .orange
        }
    }
}
