import Foundation

/// How the virtual machines in the library, and what goes with them, use the space on the library's volume.
///
/// On APFS, a clone shares its files' storage with the virtual machine it was cloned from until either of them changes,
/// so the space a virtual machine takes up isn't what deleting it frees. Deleting it only frees what no other file
/// uses; what it shares is freed once every virtual machine that shares it has been deleted.
public struct VMStorageReport: Hashable, Sendable {
    public struct Volume: Hashable, Sendable {
        public var name: String
        public var capacity: UInt64
        /// Space that's free right now.
        public var availableCapacity: UInt64
        /// Space that's free once macOS removes what it can, such as caches and local Time Machine snapshots.
        public var availableCapacityForImportantUsage: UInt64
        public var supportsCloning: Bool

        /// Space macOS can free when it needs to. Files that are deleted while a local snapshot still has them stay here until it's removed.
        public var purgeableCapacity: UInt64 {
            availableCapacityForImportantUsage - min(availableCapacity, availableCapacityForImportantUsage)
        }

        public var usedCapacity: UInt64 { capacity - min(availableCapacity, capacity) }

        public init(name: String, capacity: UInt64, availableCapacity: UInt64, availableCapacityForImportantUsage: UInt64, supportsCloning: Bool) {
            self.name = name
            self.capacity = capacity
            self.availableCapacity = availableCapacity
            self.availableCapacityForImportantUsage = availableCapacityForImportantUsage
            self.supportsCloning = supportsCloning
        }

        /// Measures the volume that the file or folder is on, or `nil` when it can't be measured, such as when it doesn't exist.
        public init?(containing url: URL) {
            let keys: Set<URLResourceKey> = [
                .volumeLocalizedNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeSupportsFileCloningKey,
            ]

            guard let values = try? url.resourceValues(forKeys: keys), let capacity = values.volumeTotalCapacity else { return nil }

            let available = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))

            self.init(
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                capacity: UInt64(max(capacity, 0)),
                availableCapacity: available,
                availableCapacityForImportantUsage: values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? available,
                supportsCloning: values.volumeSupportsFileCloning ?? false
            )
        }
    }

    /// What a file in a virtual machine is for.
    public enum Category: String, CaseIterable, Hashable, Sendable {
        case disks
        case savedSession
        case installMedia
        case system

        public var title: String {
            switch self {
            case .disks: "Disks"
            case .savedSession: "Saved session"
            case .installMedia: "Installation media"
            case .system: "System files"
            }
        }
    }

    public struct File: Identifiable, Hashable, Sendable {
        public var id: URL { url }
        public var url: URL
        /// The file's path inside the virtual machine.
        public var name: String
        public var category: Category
        public var usage: FileStorageUsage

        public init(url: URL, name: String, category: Category, usage: FileStorageUsage) {
            self.url = url
            self.name = name
            self.category = category
            self.usage = usage
        }
    }

    public struct Machine: Identifiable, Hashable, Sendable {
        public var id: VBVirtualMachine.ID
        public var uuid: UUID
        public var name: String
        public var bundleURL: URL
        public var systemType: VBGuestType
        public var copiedFrom: VBVirtualMachine.Metadata.CopySource?
        /// When the virtual machine's bundle was created, which tells which of the virtual machines that share data came first
        /// when where they came from wasn't recorded.
        public var creationDate: Date
        public var files: [File]
        /// The space the virtual machine's files take up, counting files that are identical copies of each other once.
        public var size: UInt64
        /// What deleting the virtual machine frees: what no other virtual machine uses.
        public var freedIfDeleted: UInt64
        /// Other virtual machines that share some of this one's data, found from the files themselves rather than from
        /// where they came from: files that are still identical, and files whose data is on the same blocks of the volume.
        public var sharesStorageWith: Set<UUID>
        /// Virtual machines in the Trash that share some of this one's data.
        public var sharesStorageWithTrashedItems: Set<URL>

        /// What stays after deleting the virtual machine, because other virtual machines use it too.
        public var sharedSize: UInt64 { size - min(freedIfDeleted, size) }

        /// The capacity of the virtual machine's disks, as the guest sees them.
        public var diskCapacity: UInt64 {
            files.filter { $0.category == .disks }.reduce(0) { $0 + $1.usage.logicalSize }
        }

        public func files(in category: Category) -> [File] { files.filter { $0.category == category } }

        public func allocatedSize(of category: Category) -> UInt64 {
            files(in: category).reduce(0) { $0 + $1.usage.allocatedSize }
        }

        public init(id: VBVirtualMachine.ID, uuid: UUID, name: String, bundleURL: URL, systemType: VBGuestType, copiedFrom: VBVirtualMachine.Metadata.CopySource?, creationDate: Date = .distantPast, files: [File], size: UInt64, freedIfDeleted: UInt64, sharesStorageWith: Set<UUID> = [], sharesStorageWithTrashedItems: Set<URL> = []) {
            self.id = id
            self.uuid = uuid
            self.name = name
            self.bundleURL = bundleURL
            self.systemType = systemType
            self.copiedFrom = copiedFrom
            self.creationDate = creationDate
            self.files = files
            self.size = size
            self.freedIfDeleted = freedIfDeleted
            self.sharesStorageWith = sharesStorageWith
            self.sharesStorageWithTrashedItems = sharesStorageWithTrashedItems
        }
    }

    /// A virtual machine and the ones that were copied from it, directly or not, along with ones that share data with them.
    public struct Family: Identifiable, Hashable, Sendable {
        public struct Member: Hashable, Sendable {
            public var machine: Machine
            /// How many copies away from the family's first virtual machine it is. Virtual machines that share data with the
            /// family's first virtual machine without a record of where they came from come right under it.
            public var depth: Int

            public init(machine: Machine, depth: Int) {
                self.machine = machine
                self.depth = depth
            }
        }

        public var id: VBVirtualMachine.ID { members[0].machine.id }
        /// Each virtual machine comes after the one it was copied from.
        public var members: [Member]

        public init(members: [Member]) {
            self.members = members
        }

        /// About how much space the family takes up, counting what its virtual machines share once. APFS doesn't say how
        /// much of what's shared is shared by which files, so the largest share in the family stands in for all of it.
        public var estimatedSize: UInt64 {
            members.reduce(0) { $0 + $1.machine.freedIfDeleted } + (members.map(\.machine.sharedSize).max() ?? 0)
        }
    }

    /// Something that takes up space in the library's volume on behalf of Hypervisaur, other than a virtual machine.
    public struct Item: Identifiable, Hashable, Sendable {
        public var id: URL { url }
        public var url: URL
        public var name: String
        public var size: UInt64
        public var freedIfDeleted: UInt64

        public init(url: URL, name: String, size: UInt64, freedIfDeleted: UInt64) {
            self.url = url
            self.name = name
            self.size = size
            self.freedIfDeleted = freedIfDeleted
        }
    }

    public var volume: Volume?
    public var families: [Family]
    /// Disc images and restore images downloaded for installing virtual machines.
    public var downloads: [Item]
    /// Virtual machines that were moved to the Trash, which still take up space until it's emptied.
    public var trashedMachines: [Item]
    public var date: Date

    public var machines: [Machine] { families.flatMap { $0.members.map(\.machine) } }

    public func machine(withID id: VBVirtualMachine.ID) -> Machine? { machines.first { $0.id == id } }

    public func machine(withUUID uuid: UUID) -> Machine? { machines.first { $0.uuid == uuid } }

    /// The virtual machines in the Trash that a virtual machine shares storage with.
    public func trashedRelatives(of machine: Machine) -> [Item] {
        trashedMachines.filter { machine.sharesStorageWithTrashedItems.contains($0.url) }
    }

    /// The virtual machines in the library that a virtual machine shares storage with, as far as can be told: the one it
    /// was copied from, the ones copied from it, and ones that share data with it.
    public func relatives(of machine: Machine) -> [Machine] {
        let all = machines
        var relatedUUIDs = machine.sharesStorageWith

        if let source = machine.copiedFrom?.uuid { relatedUUIDs.insert(source) }
        for other in all where other.copiedFrom?.uuid == machine.uuid { relatedUUIDs.insert(other.uuid) }

        relatedUUIDs.remove(machine.uuid)

        return all.filter { relatedUUIDs.contains($0.uuid) }
    }

    /// About how much space virtual machines take up, counting what they share once.
    public var estimatedMachinesSize: UInt64 { families.reduce(0) { $0 + $1.estimatedSize } }

    public var downloadsSize: UInt64 { downloads.reduce(0) { $0 + $1.size } }

    public var trashedMachinesSize: UInt64 { trashedMachines.reduce(0) { $0 + $1.size } }

    public init(volume: Volume?, families: [Family], downloads: [Item], trashedMachines: [Item], date: Date = .now) {
        self.volume = volume
        self.families = families
        self.downloads = downloads
        self.trashedMachines = trashedMachines
        self.date = date
    }
}
