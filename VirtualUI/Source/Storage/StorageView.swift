import SwiftUI
import VirtualCore

/// Opens the window that shows how virtual machines use storage.
public enum StorageWindow {
    @MainActor
    public static func open(library: VMLibraryController) {
        OpenCocoaWindowAction.default(id: "storage", preferredContentSize: CGSize(width: 1000, height: 680)) {
            StorageView(controller: VMStorageController(library: library))
                .environmentObject(library)
        }
    }
}

/// Shows how each virtual machine uses storage, which ones were copied from which, and what deleting each one would free.
struct StorageView: View {
    @StateObject private var controller: VMStorageController
    @State private var selection: VBVirtualMachine.ID?

    init(controller: VMStorageController, selection: VBVirtualMachine.ID? = nil) {
        _controller = StateObject(wrappedValue: controller)
        _selection = State(initialValue: selection)
    }

    var body: some View {
        Group {
            if let report = controller.report {
                content(report)
            } else {
                ProgressView("Measuring…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 880, idealWidth: 1000, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .task { await controller.observe() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.refresh(isRequested: true)
                } label: {
                    if controller.isMeasuring {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Measure Again", systemImage: "arrow.clockwise")
                    }
                }
                .help(controller.isMeasuring ? "Measuring…" : "Measure again")
                .disabled(controller.isMeasuring)
            }
        }
        .windowTitle("Storage")
        .windowStyleMask([.titled, .miniaturizable, .closable, .resizable])
    }

    private func content(_ report: VMStorageReport) -> some View {
        VStack(spacing: 0) {
            if let volume = report.volume {
                VolumeSummaryView(report: report, volume: volume)
                    .padding(20)

                Divider()
            }

            HStack(spacing: 0) {
                StorageList(report: report, controller: controller, selection: $selection)
                    .frame(minWidth: 480, maxWidth: .infinity)

                Divider()

                Group {
                    if let selection, let machine = report.machine(withID: selection) {
                        MachineStorageDetail(machine: machine, report: report, controller: controller, selection: $selection)
                            .id(machine.id)
                    } else {
                        StorageDetailPlaceholder()
                    }
                }
                .frame(width: 360)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Volume

private struct VolumeSummaryView: View {
    var report: VMStorageReport
    var volume: VMStorageReport.Volume

    private var segments: [StorageSegment] {
        let machines = report.estimatedMachinesSize
        let downloads = report.downloadsSize
        let trash = report.trashedMachinesSize
        let purgeable = volume.purgeableCapacity
        let accounted = machines + downloads + trash + purgeable
        let other = volume.usedCapacity - min(accounted, volume.usedCapacity)

        return [
            StorageSegment(title: "Virtual machines", size: machines, color: .accentColor,
                           explanation: "The virtual machines in the library. What copies of a virtual machine share is counted once."),
            StorageSegment(title: "Downloads", size: downloads, color: .purple,
                           explanation: "Installers and disc images that were downloaded to create virtual machines. They can be downloaded again."),
            StorageSegment(title: "In the Trash", size: trash, color: .orange,
                           explanation: "Virtual machines that were moved to the Trash. They take up space until you empty the Trash in the Finder."),
            StorageSegment(title: "Other files", size: other, color: .secondary.opacity(0.55),
                           explanation: "Everything else on the volume, which isn’t Hypervisaur’s."),
            StorageSegment(title: "Purgeable", size: purgeable, color: .secondary.opacity(0.25),
                           explanation: "Space that’s in use now, but that macOS frees by itself when it’s needed, such as caches, iCloud files that can be downloaded again, and local Time Machine snapshots."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(volume.name, systemImage: "internaldrive")
                    .font(.headline)

                /// The time is shown relative to now, which changes by itself.
                TimelineView(.periodic(from: report.date, by: 15)) { context in
                    Text(measuredDescription(at: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(volume.availableCapacity.formattedBytes) available of \(volume.capacity.formattedBytes)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            SegmentedStorageBar(segments: segments, total: volume.capacity)
                .frame(height: 14)

            HStack(spacing: 16) {
                ForEach(segments.filter { $0.size > 0 }) { segment in
                    StorageLegendItem(color: segment.color, title: segment.title, size: segment.size)
                        .help(segment.explanation)
                }
                StorageLegendItem(color: nil, title: "Available", size: volume.availableCapacity)
                    .help("Free space on the volume.")
            }
            .font(.caption)

            Text(volume.supportsCloning
                 ? "Copies of a virtual machine share its storage until either of them changes, so what they share is counted once. Purgeable space is freed by macOS when it’s needed, and includes files that local Time Machine snapshots still keep."
                 : "This volume can’t share storage between copies, so every copy of a virtual machine takes up its full size.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension VolumeSummaryView {
    fileprivate func measuredDescription(at now: Date) -> String {
        guard now.timeIntervalSince(report.date) >= 60 else { return "Measured just now" }
        return "Measured \(report.date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }
}

private struct StorageSegment: Identifiable {
    var id: String { title }
    var title: String
    var size: UInt64
    var color: Color
    var explanation: String
}

private struct SegmentedStorageBar: View {
    var segments: [StorageSegment]
    var total: UInt64

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments.filter { $0.size > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(2, proxy.size.width * fraction(of: segment.size)))
                        .help("\(segment.title): \(segment.size.formattedBytes). \(segment.explanation)")
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func fraction(of size: UInt64) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(size) / Double(total))
    }
}

private struct StorageLegendItem: View {
    var color: Color?
    var title: String
    var size: UInt64

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color ?? .clear)
                .overlay {
                    if color == nil {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(.secondary.opacity(0.6))
                    }
                }
                .frame(width: 9, height: 9)

            Text(title)
            Text(size.formattedBytes)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - List

private struct StorageList: View {
    var report: VMStorageReport
    @ObservedObject var controller: VMStorageController
    @Binding var selection: VBVirtualMachine.ID?

    private var largestMachine: UInt64 { report.machines.map(\.size).max() ?? 0 }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(report.families) { family in
                    ForEach(family.members, id: \.machine.id) { member in
                        MachineStorageRow(
                            machine: member.machine,
                            depth: member.depth,
                            scale: largestMachine,
                            report: report,
                            isRunning: controller.isRunning(member.machine),
                            isSaved: controller.virtualMachine(for: member.machine)?.savedSession != nil
                        )
                        .tag(member.machine.id)
                    }
                }
            } header: {
                Text("Virtual Machines")
            }

            if !report.downloads.isEmpty {
                Section {
                    ForEach(report.downloads) { item in
                        StorageItemRow(item: item, symbol: "arrow.down.circle", canMoveToTrash: true, controller: controller)
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Installers and disc images that were downloaded to create virtual machines. They can be downloaded again.")
                }
            }

            if !report.trashedMachines.isEmpty {
                Section {
                    ForEach(report.trashedMachines) { item in
                        StorageItemRow(item: item, symbol: "trash", canMoveToTrash: false, controller: controller)
                    }
                } header: {
                    Text("In the Trash")
                } footer: {
                    Text("These virtual machines take up space until you empty the Trash in the Finder.")
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }
}

private struct MachineStorageRow: View {
    var machine: VMStorageReport.Machine
    var depth: Int
    var scale: UInt64
    var report: VMStorageReport
    var isRunning: Bool
    var isSaved: Bool

    var body: some View {
        HStack(spacing: 10) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth - 1) * 20)
            }

            GuestTypeBadge(systemType: machine.systemType, size: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(machine.name)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if isRunning {
                        StatusBadge(title: "Running", color: .green)
                    } else if isSaved {
                        StatusBadge(title: "Saved", color: .blue)
                    }
                }

                if let caption = lineageCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                MachineUsageBar(machine: machine, scale: scale)
                    .frame(height: 6)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(machine.size.formattedBytes)
                    .fontWeight(.semibold)
                Text("frees \(machine.freedIfDeleted.formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private var lineageCaption: String? {
        guard let source = machine.copiedFrom else {
            let copies = report.machines.filter { $0.copiedFrom?.uuid == machine.uuid }.count
            if copies > 0 { return "Original of \(copies) \(copies == 1 ? "copy" : "copies")" }

            /// Copies made before Hypervisaur recorded where they came from are only known from the data they share.
            let relatives = report.relatives(of: machine).map(\.name)
            guard !relatives.isEmpty else { return nil }
            return "Shares disk data with \(relatives.formatted(.list(type: .and)))"
        }

        let kind = source.kind == .clone ? "Clone" : "Duplicate"
        let isInLibrary = report.machine(withUUID: source.uuid) != nil
        return "\(kind) of \(source.name)\(isInLibrary ? "" : " (no longer in the library)") · \(source.date.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// What deleting a virtual machine frees, followed by what it shares, at a scale shared by every row.
private struct MachineUsageBar: View {
    /// What's shared is drawn in a lighter shade of what's freed.
    static let sharedOpacity = 0.5

    var machine: VMStorageReport.Machine
    var scale: UInt64

    /// Selected rows have an accent-coloured background.
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var color: Color { backgroundProminence == .increased ? .white : .accentColor }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * fraction(machine.size, of: scale)

            HStack(spacing: 1) {
                Rectangle()
                    .fill(color)
                    .frame(width: width * fraction(machine.freedIfDeleted, of: machine.size))
                Rectangle()
                    .fill(color.opacity(Self.sharedOpacity))
                Spacer(minLength: 0)
            }
            .frame(width: max(width, 3), alignment: .leading)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: Capsule())
        }
        .help("Frees \(machine.freedIfDeleted.formattedBytes) if deleted. \(machine.sharedSize.formattedBytes) is shared with other virtual machines.")
    }

    private func fraction(_ value: UInt64, of total: UInt64) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(Double(value) / Double(total), 1))
    }
}

private struct StorageItemRow: View {
    var item: VMStorageReport.Item
    var symbol: String
    var canMoveToTrash: Bool
    @ObservedObject var controller: VMStorageController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(item.size.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")

            if canMoveToTrash {
                Button {
                    Task { await moveToTrash() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Move to Trash")
            }
        }
        .padding(.vertical, 2)
    }

    private func moveToTrash() async {
        let alert = NSAlert()
        alert.messageText = "Move “\(item.name)” to the Trash?"
        alert.informativeText = "It frees \(item.freedIfDeleted.formattedBytes) once you empty the Trash. It can be downloaded again if you need it."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard await alert.present(from: NSApp.keyWindow) == .alertFirstButtonReturn else { return }

        do {
            try await NSWorkspace.shared.recycle([item.url])
        } catch {
            NSApp.presentError(error)
        }

        controller.refresh()
    }
}

// MARK: - Detail

private struct StorageDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Select a virtual machine to see how it uses storage.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                StorageKey(color: .accentColor, text: "Only this virtual machine uses it, so deleting it frees this.")
                StorageKey(color: .accentColor.opacity(MachineUsageBar.sharedOpacity), text: "Shared with copies of it, or the one it was copied from. It’s freed once all of them are deleted.")
            }
            .font(.caption)
            .padding(.top, 8)
        }
        .padding(28)
    }
}

private struct StorageKey: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MachineStorageDetail: View {
    var machine: VMStorageReport.Machine
    var report: VMStorageReport
    @ObservedObject var controller: VMStorageController
    @Binding var selection: VBVirtualMachine.ID?

    @EnvironmentObject private var library: VMLibraryController

    private var relatives: [VMStorageReport.Machine] { report.relatives(of: machine) }

    private var trashedRelatives: [VMStorageReport.Item] { report.trashedRelatives(of: machine) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(spacing: 10) {
                    StorageStat(title: "Takes up", size: machine.size, color: .primary)
                    StorageStat(title: "Frees if deleted", size: machine.freedIfDeleted, color: .accentColor)
                    StorageStat(title: "Shared", size: machine.sharedSize, color: .secondary)
                }

                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !relatives.isEmpty || !trashedRelatives.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shares storage with")
                            .font(.subheadline.weight(.semibold))

                        ForEach(relatives) { relative in
                            Button {
                                selection = relative.id
                            } label: {
                                HStack(spacing: 8) {
                                    GuestTypeBadge(systemType: relative.systemType, size: 18)
                                    Text(relative.name)
                                    Spacer()
                                    Text(relationship(to: relative))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(trashedRelatives) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.orange)
                                    .frame(width: 18)
                                Text(item.name)
                                Spacer()
                                Text("in the Trash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("What it’s made of")
                        .font(.subheadline.weight(.semibold))

                    ForEach(VMStorageReport.Category.allCases, id: \.self) { category in
                        let size = machine.allocatedSize(of: category)
                        if size > 0 {
                            CategoryRow(title: category.title, detail: detail(for: category), size: size, total: machine.size)
                        }
                    }
                }

                DisclosureGroup("Files") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(machine.files.filter { $0.usage.allocatedSize > 0 }) { file in
                            HStack(alignment: .firstTextBaseline) {
                                Text(file.name)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(file.usage.allocatedSize.formattedBytes)
                                    .font(.caption)
                                    .monospacedDigit()
                                if file.usage.sharedSize > 0 {
                                    Text("\(file.usage.sharedSize.formattedBytes) shared")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }

                Divider()

                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([machine.bundleURL])
                    }

                    Spacer()

                    Button("Move to Trash…", role: .destructive) {
                        guard let vm = controller.virtualMachine(for: machine) else { return }
                        Task {
                            guard await MoveToTrashConfirmation.confirm(vm, library: library, from: NSApp.keyWindow) else { return }
                            library.performMoveToTrash(for: vm)
                        }
                    }
                    .disabled(controller.isRunning(machine))
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            GuestTypeBadge(systemType: machine.systemType, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                if let source = machine.copiedFrom {
                    Text("\(source.kind == .clone ? "Cloned" : "Duplicated") from \(source.name) on \(source.date.formatted(date: .long, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var explanation: String {
        let freed = machine.freedIfDeleted.formattedBytes

        guard machine.sharedSize > Self.negligibleSize else {
            return "Nothing it uses is shared, so deleting it frees all \(machine.size.formattedBytes) once you empty the Trash."
        }

        let shared = machine.sharedSize.formattedBytes
        let names = relatives.map { "“\($0.name)”" } + trashedRelatives.map { "“\($0.name)” in the Trash" }

        if names.isEmpty {
            return "Deleting it frees about \(freed). \(shared) is shared with other files on the volume, outside the library, and is only freed once they’re deleted too."
        }

        return "Deleting it frees about \(freed). \(shared) is shared with \(names.formatted(.list(type: .and))), and is only freed once \(names.count == 1 ? "that’s" : "they’re") deleted too."
    }

    /// Sharing a few blocks of metadata doesn't matter to anyone.
    private static let negligibleSize: UInt64 = 1 << 20

    private func relationship(to relative: VMStorageReport.Machine) -> String {
        if machine.copiedFrom?.uuid == relative.uuid { return "copied from" }
        if relative.copiedFrom?.uuid == machine.uuid { return relative.copiedFrom?.kind == .clone ? "clone" : "duplicate" }
        return "shares disk data"
    }

    private func detail(for category: VMStorageReport.Category) -> String? {
        switch category {
        case .disks:
            let disks = machine.files(in: .disks)
            let capacity = machine.diskCapacity.formattedBytes
            return disks.count == 1 ? "\(capacity) disk" : "\(disks.count) disks, \(capacity) in all"
        case .savedSession:
            return "Memory and copies of the disks from when it was saved"
        case .installMedia:
            return "Attached while setting up the operating system"
        case .system:
            return nil
        }
    }
}

private struct StorageStat: View {
    var title: String
    var size: UInt64
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(size.formattedBytes)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CategoryRow: View {
    var title: String
    var detail: String?
    var size: UInt64
    var total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(size.formattedBytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(3, proxy.size.width * CGFloat(total > 0 ? min(Double(size) / Double(total), 1) : 0)))
            }
            .frame(height: 4)
            .background(.quaternary.opacity(0.4), in: Capsule())

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared Components

private struct GuestTypeBadge: View {
    var systemType: VBGuestType
    var size: CGFloat

    var body: some View {
        systemType.icon
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.white)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

private struct StatusBadge: View {
    var title: String
    var color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

extension UInt64 {
    /// The size as the Finder would show it.
    var formattedBytes: String {
        Int64(clamping: self).formatted(.byteCount(style: .file))
    }
}

#if DEBUG
extension VMStorageReport {
    static var preview: VMStorageReport {
        let gigabyte: UInt64 = 1_000_000_000

        func machine(_ name: String, _ type: VBGuestType, size: UInt64, freed: UInt64, uuid: UUID = UUID(), from source: (UUID, String, VBVirtualMachine.Metadata.CopySource.Kind)? = nil, savedSession: UInt64 = 0) -> Machine {
            let bundleURL = URL(fileURLWithPath: "/Users/Shared/Hypervisaur/\(name).vbvm")
            var files = [
                File(url: bundleURL.appending(path: "Disk.img"), name: "Disk.img", category: .disks, usage: FileStorageUsage(logicalSize: 128 * gigabyte, allocatedSize: size - savedSession - gigabyte / 4, privateSize: freed)),
                File(url: bundleURL.appending(path: "AuxiliaryStorage"), name: "AuxiliaryStorage", category: .system, usage: FileStorageUsage(logicalSize: gigabyte / 4, allocatedSize: gigabyte / 4, privateSize: 0)),
            ]
            if savedSession > 0 {
                files.append(File(url: bundleURL.appending(path: "SavedSession/State.vzvmsave"), name: "SavedSession/State.vzvmsave", category: .savedSession, usage: FileStorageUsage(logicalSize: savedSession, allocatedSize: savedSession, privateSize: savedSession)))
            }
            return Machine(
                id: bundleURL.absoluteString,
                uuid: uuid,
                name: name,
                bundleURL: bundleURL,
                systemType: type,
                copiedFrom: source.map { .init(uuid: $0.0, name: $0.1, date: .now.addingTimeInterval(-86_400 * 3), kind: $0.2) },
                files: files,
                size: size,
                freedIfDeleted: freed
            )
        }

        let windowsUUID = UUID()
        let windows = machine("Windows 11", .windows, size: 38 * gigabyte, freed: 6 * gigabyte, uuid: windowsUUID)
        let clone = machine("Clone of Windows 11", .windows, size: 35 * gigabyte, freed: 3 * gigabyte, from: (windowsUUID, "Windows 11", .clone))
        let cloneUUID = clone.uuid
        let cloneOfClone = machine("Test Build", .windows, size: 33 * gigabyte, freed: 1 * gigabyte, from: (cloneUUID, "Clone of Windows 11", .clone))
        let sequoia = machine("macOS 26", .mac, size: 52 * gigabyte, freed: 52 * gigabyte, savedSession: 8 * gigabyte)
        let ubuntu = machine("Ubuntu 26.04", .linux, size: 9 * gigabyte, freed: 1 * gigabyte, from: (UUID(), "Ubuntu Base", .duplicate))

        return VMStorageReport(
            volume: Volume(name: "Macintosh HD", capacity: 1_000 * gigabyte, availableCapacity: 412 * gigabyte, availableCapacityForImportantUsage: 455 * gigabyte, supportsCloning: true),
            families: [
                Family(members: [.init(machine: sequoia, depth: 0)]),
                Family(members: [.init(machine: windows, depth: 0), .init(machine: clone, depth: 1), .init(machine: cloneOfClone, depth: 2)]),
                Family(members: [.init(machine: ubuntu, depth: 0)]),
            ],
            downloads: [
                Item(url: URL(fileURLWithPath: "/Users/Shared/Hypervisaur/_Downloads/UniversalMac_26.1_Restore.ipsw"), name: "UniversalMac_26.1_Restore", size: 17 * gigabyte, freedIfDeleted: 17 * gigabyte),
                Item(url: URL(fileURLWithPath: "/Users/Shared/Hypervisaur/_Downloads/Win11_ARM64.iso"), name: "Win11_ARM64", size: 6 * gigabyte, freedIfDeleted: 6 * gigabyte),
            ],
            trashedMachines: [
                Item(url: URL(fileURLWithPath: "/Users/neil/.Trash/Old Windows.vbvm"), name: "Old Windows", size: 31 * gigabyte, freedIfDeleted: 2 * gigabyte),
            ]
        )
    }
}

#Preview("Storage") {
    StorageView(controller: VMStorageController(report: .preview))
        .environmentObject(VMLibraryController.preview)
        .frame(width: 1000, height: 680)
}

#Preview("Storage - Clone Selected") {
    let report = VMStorageReport.preview
    StorageView(controller: VMStorageController(report: report), selection: report.families[1].members[1].machine.id)
        .environmentObject(VMLibraryController.preview)
        .frame(width: 1000, height: 680)
}
#endif
