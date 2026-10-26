import Foundation

/// Works out how virtual machines and what goes with them use the space on the library's volume. See ``VMStorageReport``.
public struct VMStorageAnalyzer: Sendable {
    /// What's needed to measure a virtual machine, taken from it on the main actor.
    public struct Input: Sendable {
        public var id: VBVirtualMachine.ID
        public var uuid: UUID
        public var name: String
        public var bundleURL: URL
        public var systemType: VBGuestType
        public var copiedFrom: VBVirtualMachine.Metadata.CopySource?
        public var creationDate: Date
        /// The paths of the disk images inside the bundle, relative to it.
        public var diskPaths: Set<String>

        public init(_ vm: VBVirtualMachine) {
            id = vm.id
            uuid = vm.uuid
            name = vm.name
            bundleURL = vm.bundleURL
            systemType = vm.configuration.systemType
            copiedFrom = vm.metadata.copiedFrom
            creationDate = vm.bundleURL.creationDate
            diskPaths = Set(vm.configuration.hardware.storageDevices.compactMap { device -> String? in
                guard case .managedImage(let image) = device.backing else { return nil }
                return Self.relativePath(of: vm.diskImageURL(for: image), in: vm.bundleURL)
            })
        }

        static func relativePath(of url: URL, in bundleURL: URL) -> String? {
            let bundlePath = bundleURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(bundlePath + "/") else { return nil }
            return String(path.dropFirst(bundlePath.count + 1))
        }
    }

    public var libraryURL: URL
    public var downloadsURL: URL?

    public init(libraryURL: URL, downloadsURL: URL?) {
        self.libraryURL = libraryURL
        self.downloadsURL = downloadsURL
    }

    /// Measures everything. Reading the files' attributes takes a moment for large libraries, so this shouldn't run on the main actor.
    /// - Parameter includingOtherItems: Whether downloads and virtual machines in the Trash are measured too.
    public func analyze(_ inputs: [Input], includingOtherItems: Bool = true) -> VMStorageReport {
        var machines = inputs.map(measure)

        let trashed = includingOtherItems
            ? trashURL.map { measureItems(in: $0, samplingSharedData: true) { $0.pathExtension == VBVirtualMachine.bundleExtension } } ?? []
            : []

        Self.findSharing(among: &machines, trashed: trashed)

        return VMStorageReport(
            volume: measureVolume(),
            families: Self.families(of: machines),
            downloads: includingOtherItems ? downloadsURL.map { measureItems(in: $0, samplingSharedData: false) { _ in true } }?.map(\.item) ?? [] : [],
            trashedMachines: trashed.map(\.item)
        )
    }

    /// Works out which virtual machines share data, which also covers copies that were made before Hypervisaur recorded
    /// where copies came from: files that are still identical to another virtual machine's have the same clone ID, and
    /// files that have changed since but still share data have it on the same blocks of the volume.
    static func findSharing(among machines: inout [VMStorageReport.Machine], trashed: [(item: VMStorageReport.Item, samples: Set<Int64>)]) {
        var ownersByCloneID = [UInt64: Set<UUID>]()
        for machine in machines {
            for file in machine.files where file.usage.cloneReferenceCount > 1 {
                guard let cloneID = file.usage.cloneID else { continue }
                ownersByCloneID[cloneID, default: []].insert(machine.uuid)
            }
        }

        let samples = machines.map { sharedDataSamples(of: $0.files.map(\.url), usages: $0.files.map(\.usage)) }

        for index in machines.indices {
            var related = Set<UUID>()
            for file in machines[index].files {
                guard let cloneID = file.usage.cloneID else { continue }
                related.formUnion(ownersByCloneID[cloneID] ?? [])
            }
            for other in machines.indices where other != index && PhysicalBlockSampler.indicateSharing(samples[index], samples[other]) {
                related.insert(machines[other].uuid)
            }
            related.remove(machines[index].uuid)
            machines[index].sharesStorageWith = related

            machines[index].sharesStorageWithTrashedItems = Set(trashed.filter { PhysicalBlockSampler.indicateSharing(samples[index], $0.samples) }.map(\.item.url))
        }
    }

    /// Where the data of the files that share some of it is on the volume. Small files aren't worth sampling.
    static func sharedDataSamples(of urls: [URL], usages: [FileStorageUsage]) -> Set<Int64> {
        zip(urls, usages)
            .filter { $1.sharedSize > 1 << 20 && $1.allocatedSize >= 16 << 20 }
            .reduce(into: Set<Int64>()) { $0.formUnion(PhysicalBlockSampler.samples(of: $1.0)) }
    }

    // MARK: - Virtual Machines

    func measure(_ input: Input) -> VMStorageReport.Machine {
        let files = Self.regularFiles(in: input.bundleURL).compactMap { url -> VMStorageReport.File? in
            guard let usage = FileStorageUsage.measure(url),
                  let name = Input.relativePath(of: url, in: input.bundleURL)
            else { return nil }

            return VMStorageReport.File(url: url, name: name, category: Self.category(of: name, diskPaths: input.diskPaths), usage: usage)
        }
        .sorted { $0.usage.allocatedSize > $1.usage.allocatedSize }

        let space = Self.space(of: files.map(\.usage))

        return VMStorageReport.Machine(
            id: input.id,
            uuid: input.uuid,
            name: input.name,
            bundleURL: input.bundleURL,
            systemType: input.systemType,
            copiedFrom: input.copiedFrom,
            creationDate: input.creationDate,
            files: files,
            size: space.size,
            freedIfDeleted: space.freedIfDeleted
        )
    }

    static func category(of path: String, diskPaths: Set<String>) -> VMStorageReport.Category {
        let firstComponent = path.split(separator: "/").first.map(String.init) ?? path

        if firstComponent.hasPrefix(SavedSessionLayout.packageName) { return .savedSession }
        if diskPaths.contains(path) { return .disks }
        if ["Installer.img", "Drivers.img"].contains(path) { return .installMedia }
        return .system
    }

    /// How much space the files take up together, and what deleting all of them frees.
    ///
    /// Files that are clones of each other with no changes, such as a saved virtual machine's disks and their copies in its
    /// saved session, share one clone ID and take up the space of one of them. A file's private size leaves out what it
    /// shares with its clones, even when all of them are among these files, so data whose clones are all here is freed with them.
    static func space(of files: [FileStorageUsage]) -> (size: UInt64, freedIfDeleted: UInt64) {
        var size: UInt64 = 0
        var freed: UInt64 = 0
        var groups = [UInt64: [FileStorageUsage]]()

        for file in files {
            if let cloneID = file.cloneID, file.cloneReferenceCount > 1 {
                groups[cloneID, default: []].append(file)
            } else {
                size += file.allocatedSize
                freed += file.privateSize
            }
        }

        for group in groups.values {
            let groupSize = group.map(\.allocatedSize).max() ?? 0
            size += groupSize

            if group.count >= Int(group[0].cloneReferenceCount) {
                freed += groupSize
            } else {
                freed += group.reduce(0) { $0 + $1.privateSize }
            }
        }

        return (size, min(freed, size))
    }

    /// Groups virtual machines into families: each one goes with the one it was copied from, if that's still in the
    /// library, and with the ones whose files are still identical to its own.
    static func families(of machines: [VMStorageReport.Machine]) -> [VMStorageReport.Family] {
        let byUUID = Dictionary(machines.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })

        var parent = [UUID: UUID]()
        func root(of uuid: UUID) -> UUID {
            var current = uuid
            while let next = parent[current], next != current { current = next }
            return current
        }
        func join(_ a: UUID, _ b: UUID) {
            let rootA = root(of: a), rootB = root(of: b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        for machine in machines {
            if let source = machine.copiedFrom?.uuid, byUUID[source] != nil { join(source, machine.uuid) }
            for owner in machine.sharesStorageWith where byUUID[owner] != nil { join(owner, machine.uuid) }
        }

        let grouped = Dictionary(grouping: machines) { root(of: $0.uuid) }

        return grouped.values.map { group in
            let uuids = Set(group.map(\.uuid))
            /// A virtual machine is a child of the one it was copied from, as long as that's in the same family.
            func children(of machine: VMStorageReport.Machine) -> [VMStorageReport.Machine] {
                group.filter { $0.copiedFrom?.uuid == machine.uuid }.sorted { ($0.copiedFrom?.date ?? .distantPast) < ($1.copiedFrom?.date ?? .distantPast) }
            }

            var members = [VMStorageReport.Family.Member]()
            func add(_ machine: VMStorageReport.Machine, depth: Int) {
                guard !members.contains(where: { $0.machine.uuid == machine.uuid }) else { return }
                members.append(.init(machine: machine, depth: depth))
                for child in children(of: machine) { add(child, depth: depth + 1) }
            }

            /// The virtual machine that came first leads the family. The others that weren't copied from a virtual machine in the
            /// family share data with it without a record of where they came from, so they're likely copies of it, and come under it.
            let roots = group
                .filter { machine in machine.copiedFrom.map { !uuids.contains($0.uuid) } ?? true }
                .sorted { ($0.creationDate, $1.size) < ($1.creationDate, $0.size) }

            if let first = roots.first {
                members.append(.init(machine: first, depth: 0))
                for machine in roots.dropFirst() { add(machine, depth: 1) }
                for child in children(of: first) { add(child, depth: 1) }
            }
            /// Copies of copies whose chain leads back into the family in a loop, which can only happen with damaged metadata.
            for machine in group { add(machine, depth: 0) }

            return VMStorageReport.Family(members: members)
        }
        .sorted { $0.estimatedSize > $1.estimatedSize }
    }

    private static func regularFiles(in directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    // MARK: - Everything Else

    /// The Trash on the library's volume, where virtual machines that are moved to the Trash end up.
    private var trashURL: URL? {
        try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: libraryURL, create: false)
    }

    /// - Parameter samplingSharedData: Whether to find out where the data that the items share is, so that the virtual
    ///   machines that share it can be found.
    private func measureItems(in directoryURL: URL, samplingSharedData: Bool, including include: (URL) -> Bool) -> [(item: VMStorageReport.Item, samples: Set<Int64>)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

        return urls.filter(include).compactMap { url -> (item: VMStorageReport.Item, samples: Set<Int64>)? in
            let fileURLs = Self.isDirectory(url) ? Self.regularFiles(in: url) : [url]
            let measured = fileURLs.compactMap { fileURL in FileStorageUsage.measure(fileURL).map { (fileURL, $0) } }
            guard !measured.isEmpty else { return nil }

            let space = Self.space(of: measured.map(\.1))
            let item = VMStorageReport.Item(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                size: space.size,
                freedIfDeleted: space.freedIfDeleted
            )

            return (item, samplingSharedData ? Self.sharedDataSamples(of: measured.map(\.0), usages: measured.map(\.1)) : [])
        }
        .sorted { $0.item.size > $1.item.size }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func measureVolume() -> VMStorageReport.Volume? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeSupportsFileCloningKey,
        ]

        guard let values = try? libraryURL.resourceValues(forKeys: keys), let capacity = values.volumeTotalCapacity else { return nil }

        let available = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))

        return VMStorageReport.Volume(
            name: values.volumeLocalizedName ?? libraryURL.lastPathComponent,
            capacity: UInt64(max(capacity, 0)),
            availableCapacity: available,
            availableCapacityForImportantUsage: values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? available,
            supportsCloning: values.volumeSupportsFileCloning ?? false
        )
    }
}
