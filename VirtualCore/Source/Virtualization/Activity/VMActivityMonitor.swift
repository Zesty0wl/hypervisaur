import Foundation
import Combine

/// What a virtual machine in the library is doing.
public enum VMActivityStatus: Hashable, Sendable {
    case poweredOff
    /// Not running, with a session saved to resume later.
    case saved
    case starting
    case running
    case paused
    case saving
    case restoring

    public var isRunning: Bool {
        switch self {
        case .starting, .running, .paused, .saving, .restoring: true
        case .poweredOff, .saved: false
        }
    }
}

/// How much of the Mac a running virtual machine is using.
public struct VMResourceUsage: Hashable, Sendable {
    /// The share of the virtual machine's processors it's using, from 0 to 1.
    public var processor: Double
    /// Recent values of ``processor``, oldest first.
    public var processorHistory: [Double]
    /// The Mac's memory that the virtual machine is using, in bytes.
    public var memory: UInt64
    /// How many bytes a second the virtual machine read from and wrote to disk since the previous sample.
    public var disk: Double
}

/// What one virtual machine is doing, for something that shows only that virtual machine. It changes only when that
/// virtual machine's figures do, rather than whenever any in the library do.
@MainActor
public final class VMActivity: ObservableObject {
    @Published public fileprivate(set) var status = VMActivityStatus.poweredOff
    /// What the virtual machine is using, while it runs and once it has been measured.
    @Published public fileprivate(set) var usage: VMResourceUsage?
    /// The space the virtual machine's files take up on disk, in bytes, once it has been measured.
    @Published public fileprivate(set) var storage: UInt64?

    fileprivate init() {}
}

/// Keeps track of what each virtual machine in the library is doing and, while it runs, how much processor time, memory
/// and disk activity it uses, for as long as something is showing it.
@MainActor
public final class VMActivityMonitor: ObservableObject {
    @Published public private(set) var statuses = [VBVirtualMachine.ID: VMActivityStatus]() {
        didSet { updateActivities() }
    }
    @Published public private(set) var usage = [VBVirtualMachine.ID: VMResourceUsage]() {
        didSet { updateActivities() }
    }
    /// The space each virtual machine's files take up on disk, in bytes.
    @Published public private(set) var storage = [VBVirtualMachine.ID: UInt64]() {
        didSet { updateActivities() }
    }
    /// The volume the library is on, measured as often as ``storage``.
    @Published public private(set) var libraryVolume: VMStorageReport.Volume?

    public static let sampleInterval = Duration.seconds(2)
    /// How many samples ``VMResourceUsage/processorHistory`` keeps.
    public static let historyLength = 30

    private static let storageInterval = Duration.seconds(30)

    private unowned let library: VMLibraryController
    private let sampler = VMActivitySampler(historyLength: historyLength)
    private var observerCount = 0
    private var samplingTask: Task<Void, Never>?
    private var lastStorageUpdate: ContinuousClock.Instant?
    private var cancellables = Set<AnyCancellable>()
    private var activities = [VBVirtualMachine.ID: VMActivity]()

    init(library: VMLibraryController) {
        self.library = library
    }

    /// What one virtual machine is doing, kept up to date along with the figures for the whole library.
    public func activity(for id: VBVirtualMachine.ID) -> VMActivity {
        if let activity = activities[id] { return activity }

        let activity = VMActivity()
        update(activity, for: id)
        activities[id] = activity
        return activity
    }

    private func updateActivities() {
        for (id, activity) in activities {
            update(activity, for: id)
        }
    }

    private func update(_ activity: VMActivity, for id: VBVirtualMachine.ID) {
        let status = statuses[id] ?? .poweredOff
        let usage = status.isRunning ? usage[id] : nil
        let storage = storage[id]

        /// Setting a property publishes a change even when it's the same, which would update the views showing it.
        if activity.status != status { activity.status = status }
        if activity.usage != usage { activity.usage = usage }
        if activity.storage != storage { activity.storage = storage }
    }

    /// Keeps the figures up to date until the calling task is cancelled.
    public func observe() async {
        observerCount += 1
        if observerCount == 1 { start() }

        /// Sleeps until the task that's showing the figures is cancelled.
        try? await Task.sleep(nanoseconds: .max)

        observerCount -= 1
        if observerCount == 0 { stop() }
    }

    private func start() {
        /// Starting and stopping is shown straight away, rather than at the next sample. The library publishes the change
        /// before it's made, so the statuses are worked out once it has been.
        library.$bootedMachineIdentifiers
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatuses() }
            }
            .store(in: &cancellables)

        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    private func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        cancellables.removeAll()
    }

    private func updateStatuses() {
        var statuses = [VBVirtualMachine.ID: VMActivityStatus]()
        for vm in library.virtualMachines {
            statuses[vm.id] = status(of: vm)
        }
        activities = activities.filter { id, _ in statuses[id] != nil }
        if statuses != self.statuses { self.statuses = statuses }
    }

    private func status(of vm: VBVirtualMachine) -> VMActivityStatus {
        let isBooted = library.bootedMachineIdentifiers.contains(vm.id)

        switch library.activeController(for: vm.id)?.state {
        case .starting, .resizingDisk: return .starting
        case .running: return .running
        case .paused: return .paused
        case .saving: return .saving
        case .restoring: return .restoring
        case .saved, .recoveryRequired: return .saved
        case .idle, .stopped, nil:
            /// Virtual machines started without a window, such as by automation, only show up as booted.
            if isBooted { return .running }
            return vm.savedSession != nil ? .saved : .poweredOff
        }
    }

    private func sample() async {
        updateStatuses()

        let running = library.virtualMachines
            .filter { statuses[$0.id]?.isRunning == true }
            .map { VMActivitySampler.Machine(id: $0.id, bundleURL: $0.bundleURL, processorCount: $0.configuration.hardware.cpuCount) }

        let now = ContinuousClock.now
        let measuresStorage = lastStorageUpdate.map { now - $0 >= Self.storageInterval } ?? true
            || library.virtualMachines.contains { storage[$0.id] == nil }
        let storageBundles = measuresStorage ? library.virtualMachines.map { ($0.id, $0.bundleURL) } : []

        let result = await sampler.sample(running, storageOf: storageBundles, volumeContaining: measuresStorage ? library.libraryURL : nil)

        guard !Task.isCancelled else { return }

        if result.usage != usage { usage = result.usage }
        if measuresStorage {
            lastStorageUpdate = now
            if result.storage != storage { storage = result.storage }
            if result.volume != libraryVolume { libraryVolume = result.volume }
        }
    }
}

/// Measures virtual machines away from the main thread, remembering what it needs between samples.
private actor VMActivitySampler {
    struct Machine: Sendable {
        var id: VBVirtualMachine.ID
        var bundleURL: URL
        var processorCount: Int
    }

    struct Result: Sendable {
        var usage: [VBVirtualMachine.ID: VMResourceUsage]
        var storage: [VBVirtualMachine.ID: UInt64]
        var volume: VMStorageReport.Volume?
    }

    private struct Previous {
        var pid: pid_t
        var processorTime: Duration
        var diskBytes: UInt64
        var date: ContinuousClock.Instant
        var history: [Double]
    }

    private let historyLength: Int
    private var previous = [VBVirtualMachine.ID: Previous]()

    init(historyLength: Int) {
        self.historyLength = historyLength
    }

    func sample(_ machines: [Machine], storageOf bundles: [(VBVirtualMachine.ID, URL)], volumeContaining volumeURL: URL?) -> Result {
        previous = previous.filter { id, _ in machines.contains { $0.id == id } }

        var candidates: [pid_t]?
        var usage = [VBVirtualMachine.ID: VMResourceUsage]()

        for machine in machines {
            var pid = previous[machine.id]?.pid
            if let known = pid, !VMProcessInspector.isProcess(known, runningBundleAt: machine.bundleURL) {
                pid = nil
                previous[machine.id] = nil
            }
            if pid == nil {
                if candidates == nil { candidates = VMProcessInspector.candidateProcesses() }
                pid = VMProcessInspector.process(forBundleAt: machine.bundleURL, among: candidates ?? [])
            }

            guard let pid, let sample = VMProcessInspector.sample(pid) else { continue }

            let now = ContinuousClock.now
            var history = previous[machine.id]?.history ?? []
            var disk: Double = 0

            if let last = previous[machine.id], last.pid == pid {
                let elapsed = (now - last.date) / .seconds(1)
                let used = (sample.processorTime - last.processorTime) / .seconds(1)
                let share = elapsed > 0 ? used / (elapsed * Double(max(machine.processorCount, 1))) : 0
                history.append(min(max(share, 0), 1))
                history.removeFirst(max(history.count - historyLength, 0))

                if elapsed > 0, sample.diskBytes >= last.diskBytes {
                    disk = Double(sample.diskBytes - last.diskBytes) / elapsed
                }
            }

            previous[machine.id] = Previous(pid: pid, processorTime: sample.processorTime, diskBytes: sample.diskBytes, date: now, history: history)

            /// Rates need two samples, so they aren't reported until the second one.
            guard let current = history.last else { continue }
            usage[machine.id] = VMResourceUsage(processor: current, processorHistory: history, memory: sample.memoryFootprint, disk: disk)
        }

        var storage = [VBVirtualMachine.ID: UInt64]()
        for (id, bundleURL) in bundles {
            storage[id] = Self.allocatedSize(of: bundleURL)
        }

        return Result(usage: usage, storage: storage, volume: volumeURL.flatMap(VMStorageReport.Volume.init(containing:)))
    }

    /// The space the bundle's files take up, which is less than their size for disk images with empty space in them.
    private static func allocatedSize(of bundleURL: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: Array(keys)) else { return 0 }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
