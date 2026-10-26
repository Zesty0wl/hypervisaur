import Foundation
import Testing
import Virtualization
@testable import VirtualCore

final class VMStorageAnalyzerTests {
    private let directoryURL: URL
    private static let diskSize = 4 << 20

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "VMStorageAnalyzerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    @Test func clonesShareTheirDataUntilEitherOneChanges() throws {
        let original = directoryURL.appending(path: "original")
        let clone = directoryURL.appending(path: "clone")
        try Self.randomData(count: Self.diskSize).write(to: original)
        #expect(clonefile(original.path, clone.path, 0) == 0)

        let before = try #require(FileStorageUsage.measure(clone))
        #expect(before.allocatedSize >= UInt64(Self.diskSize))
        #expect(before.privateSize == 0)
        #expect(before.sharedSize == before.allocatedSize)
        #expect(before.cloneReferenceCount == 2)
        #expect(before.cloneID == FileStorageUsage.measure(original)?.cloneID)

        let handle = try FileHandle(forWritingTo: clone)
        try handle.seek(toOffset: 1 << 20)
        try handle.write(contentsOf: Self.randomData(count: 1 << 20))
        try handle.close()

        let after = try #require(FileStorageUsage.measure(clone))
        #expect(after.privateSize >= 1 << 20)
        #expect(after.privateSize < after.allocatedSize, "what wasn't changed is still shared with the original")
        #expect(after.cloneReferenceCount == 1)
    }

    @Test func deletingAVirtualMachineThatWasClonedOnlyFreesWhatsItsOwn() throws {
        let original = try makeVirtualMachine(named: "Original")
        let clone = try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Clone of Original"), guestIdentity: .new)

        let report = analyze([original, clone])

        let originalReport = try #require(report.machine(withUUID: original.uuid))
        let cloneReport = try #require(report.machine(withUUID: clone.uuid))

        #expect(originalReport.files(in: .disks).map(\.name) == ["Disk.img"])
        #expect(originalReport.sharedSize >= UInt64(Self.diskSize), "the disk is shared with the clone")
        #expect(originalReport.freedIfDeleted < UInt64(Self.diskSize))
        #expect(cloneReport.freedIfDeleted < UInt64(Self.diskSize))

        #expect(report.families.count == 1)
        #expect(report.families[0].members.map(\.machine.uuid) == [original.uuid, clone.uuid])
        #expect(report.families[0].members.map(\.depth) == [0, 1])
        #expect(report.relatives(of: originalReport).map(\.uuid) == [clone.uuid])
    }

    @Test func copiesRecordWhereTheyCameFrom() throws {
        let original = try makeVirtualMachine(named: "Original")

        let clone = try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Clone"), guestIdentity: .new)
        let copy = try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Copy"), guestIdentity: .original)

        #expect(clone.metadata.copiedFrom?.uuid == original.uuid)
        #expect(clone.metadata.copiedFrom?.name == "Original")
        #expect(clone.metadata.copiedFrom?.kind == .clone)
        #expect(copy.metadata.copiedFrom?.uuid == original.uuid)
        #expect(copy.metadata.copiedFrom?.kind == .duplicate)
        #expect(original.metadata.copiedFrom == nil)
    }

    @Test func copiesMadeBeforeTheirOriginWasRecordedAreFoundFromIdenticalFiles() throws {
        let original = try makeVirtualMachine(named: "Original")
        let copy = try makeVirtualMachine(named: "Older Copy")
        let copyDisk = copy.bundleURL.appending(path: "Disk.img")
        try FileManager.default.removeItem(at: copyDisk)
        #expect(clonefile(original.bundleURL.appending(path: "Disk.img").path, copyDisk.path, 0) == 0)

        let report = analyze([original, copy])

        #expect(report.families.count == 1)
        #expect(report.machine(withUUID: copy.uuid)?.sharesStorageWith == [original.uuid])
    }

    @Test func copiesThatHaveChangedSinceTheyWereMadeAreFoundFromWhereTheirDataIs() throws {
        let original = try makeVirtualMachine(named: "Original", diskSize: 256 << 20)
        let copy = try makeVirtualMachine(named: "Older Copy")
        let unrelated = try makeVirtualMachine(named: "Unrelated", diskSize: 256 << 20)
        let copyDisk = copy.bundleURL.appending(path: "Disk.img")
        try FileManager.default.removeItem(at: copyDisk)
        #expect(clonefile(original.bundleURL.appending(path: "Disk.img").path, copyDisk.path, 0) == 0)

        /// Changing both of them gives them clone IDs of their own, so only where their data is still tells that they share it.
        for url in [original.bundleURL.appending(path: "Disk.img"), copyDisk] {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: 1 << 20)
            try handle.write(contentsOf: Self.randomData(count: 1 << 20))
            try handle.close()
        }

        let report = analyze([original, copy, unrelated])

        #expect(report.machine(withUUID: copy.uuid)?.sharesStorageWith == [original.uuid])
        #expect(report.machine(withUUID: unrelated.uuid)?.sharesStorageWith == [])
        #expect(report.families.count == 2)
    }

    @Test func aSavedSessionsCopiesOfTheDisksAreFreedWithItsVirtualMachine() throws {
        let vm = try makeVirtualMachine(named: "Saved")
        let resources = vm.bundleURL.appending(path: "\(SavedSessionLayout.packageName)/\(SavedSessionLayout.resourcesDirectoryName)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        #expect(clonefile(vm.bundleURL.appending(path: "Disk.img").path, resources.appending(path: "disk-0").path, 0) == 0)

        let machine = try #require(analyze([vm]).machine(withUUID: vm.uuid))

        #expect(machine.allocatedSize(of: .savedSession) >= UInt64(Self.diskSize))
        #expect(machine.freedIfDeleted >= UInt64(Self.diskSize), "the disk and its saved copy are both deleted with the virtual machine")
        #expect(machine.sharedSize < UInt64(Self.diskSize))
    }

    // MARK: - Helpers

    private func bundleURL(_ name: String) -> URL {
        directoryURL.appending(path: "\(name).\(VBVirtualMachine.bundleExtension)", directoryHint: .isDirectory)
    }

    private func makeVirtualMachine(named name: String, diskSize: Int = diskSize) throws -> VBVirtualMachine {
        var model = try VBVirtualMachine(bundleURL: bundleURL(name), isNewInstall: true)
        model.metadata.installFinished = true
        try model.saveMetadata()

        try Self.randomData(count: diskSize).write(to: model.bundleURL.appending(path: "Disk.img"))
        try VZMacMachineIdentifier().dataRepresentation.write(to: model.machineIdentifierURL)

        return try VBVirtualMachine(bundleURL: model.bundleURL, isNewInstall: false, createIfNeeded: false)
    }

    private func analyze(_ machines: [VBVirtualMachine]) -> VMStorageReport {
        VMStorageAnalyzer(libraryURL: directoryURL, downloadsURL: nil).analyze(machines.map(VMStorageAnalyzer.Input.init))
    }

    private static func randomData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }
}
