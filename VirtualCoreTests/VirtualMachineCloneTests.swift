import Foundation
import Testing
import Virtualization
@testable import VirtualCore

final class VirtualMachineCloneTests {
    private let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "VirtualMachineCloneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func bundleURL(_ name: String) -> URL {
        directoryURL.appending(path: "\(name).\(VBVirtualMachine.bundleExtension)", directoryHint: .isDirectory)
    }

    private func makeVirtualMachine(named name: String = "Original") throws -> VBVirtualMachine {
        var model = try VBVirtualMachine(bundleURL: bundleURL(name), isNewInstall: true)
        model.metadata.installFinished = true
        model.configuration.hardware.networkDevices = [VBNetworkDevice(), VBNetworkDevice(id: "second", name: "Second")]
        try model.saveMetadata()

        try Data("disk".utf8).write(to: model.bundleURL.appending(path: "Disk.img"))
        try Data("aux".utf8).write(to: model.auxiliaryStorageURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: model.machineIdentifierURL)
        try Data("hardware model".utf8).write(to: model.hardwareModelURL)

        return try VBVirtualMachine(bundleURL: model.bundleURL, isNewInstall: false, createIfNeeded: false)
    }

    @Test func cloneHasItsOwnGuestIdentity() throws {
        let original = try makeVirtualMachine()

        let clone = try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Clone of Original"), guestIdentity: .new)

        #expect(clone.uuid != original.uuid)

        let originalAddresses = Set(original.configuration.hardware.networkDevices.map(\.macAddress))
        let cloneAddresses = clone.configuration.hardware.networkDevices.map(\.macAddress)
        #expect(cloneAddresses.count == 2)
        #expect(Set(cloneAddresses).count == 2)
        #expect(originalAddresses.isDisjoint(with: cloneAddresses))
        #expect(cloneAddresses.allSatisfy { VZMACAddress(string: $0)?.isLocallyAdministeredAddress == true })

        let identifier = try #require(VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: clone.machineIdentifierURL)))
        #expect(identifier.dataRepresentation != (try Data(contentsOf: original.machineIdentifierURL)))

        /// Everything else is the same as the original's.
        #expect(try Data(contentsOf: clone.bundleURL.appending(path: "Disk.img")) == Data("disk".utf8))
        #expect(try Data(contentsOf: clone.auxiliaryStorageURL) == Data("aux".utf8))
        #expect(try Data(contentsOf: clone.hardwareModelURL) == Data("hardware model".utf8))

        var configuration = clone.configuration
        configuration.hardware.networkDevices = original.configuration.hardware.networkDevices
        #expect(configuration == original.configuration)
    }

    @Test func cloneOfGuestWithoutMachineIdentifierDoesntGetOne() throws {
        let original = try makeVirtualMachine()
        try FileManager.default.removeItem(at: original.machineIdentifierURL)

        let clone = try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Clone of Original"), guestIdentity: .new)

        #expect(!FileManager.default.fileExists(atPath: clone.machineIdentifierURL.path))
    }

    @Test func duplicateKeepsTheGuestIdentity() throws {
        let original = try makeVirtualMachine()

        let copy = try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Copy of Original"))

        #expect(copy.configuration.hardware.networkDevices == original.configuration.hardware.networkDevices)
        #expect(try Data(contentsOf: copy.machineIdentifierURL) == (try Data(contentsOf: original.machineIdentifierURL)))
    }

    @Test func guestWithASavedSessionIsntCloned() throws {
        let original = try makeVirtualMachine()
        let storage = SavedSessionStorage(bundleURL: original.bundleURL, hostECID: ProcessInfo.processInfo.machineECID)
        let plan = SavedSessionCapturePlan(
            resources: [.init(id: "disk", role: .disk, sourceURL: original.bundleURL.appending(path: "Disk.img"), workingPath: "Disk.img")],
            configuration: original.configuration,
            runtimeDescription: .init(configuration: .init()),
            screenshotSourceURL: nil,
            wasPausedBeforeSave: false,
            memorySize: 1
        )
        let staged = try storage.stageCapture(plan)
        try Data("state".utf8).write(to: staged.stateFileURL)
        try storage.publish(staged)

        let cloneURL = bundleURL("Clone of Original")
        #expect(throws: (any Error).self) {
            try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: cloneURL, guestIdentity: .new)
        }
        #expect(!FileManager.default.fileExists(atPath: cloneURL.path))
    }

    @Test func guestThatWritesToAnExternalDiskImageIsntCloned() throws {
        var original = try makeVirtualMachine()
        let imageURL = directoryURL.appending(path: "Data.img")
        try Data("data".utf8).write(to: imageURL)
        original.configuration.hardware.addOrUpdate(VBStorageDevice(isBootVolume: false, isReadOnly: false, isUSBMassStorageDevice: false, backing: .customImage(imageURL)))
        try original.saveMetadata()

        #expect(throws: (any Error).self) {
            try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Clone of Original"), guestIdentity: .new)
        }
    }

    @Test func guestThatOnlyReadsExternalDiskImagesIsCloned() throws {
        var original = try makeVirtualMachine()
        let imageURL = directoryURL.appending(path: "Installer.iso")
        try Data("installer".utf8).write(to: imageURL)
        original.configuration.hardware.addOrUpdate(VBStorageDevice(isBootVolume: false, isReadOnly: true, isUSBMassStorageDevice: false, backing: .customImage(imageURL)))
        try original.saveMetadata()

        let clone = try VMBundleDuplicator().duplicate(bundleAt: original.bundleURL, to: bundleURL("Clone of Original"), guestIdentity: .new)

        #expect(ExternalDiskImageCopier.externalDevices(of: clone).count == 1)
    }
}
