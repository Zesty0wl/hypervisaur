import Foundation
import Testing
@testable import VirtualCore

struct QEMULaunchConfigurationTests {
    @Test func windowsMachineUsesRawBootDiskAndWindowsDefaults() throws {
        let vm = try makeWindowsMachine()

        let bootImage = try vm.bootDiskImage
        #expect(bootImage.format == .raw)
        #expect(bootImage.size == VBManagedDiskImage.defaultWindowsBootDiskImageSize)
        #expect(vm.configuration.systemType == .windows)
        #expect(vm.configuration.hardware.memorySize >= VBMacDevice.minimumWindowsMemorySize || ProcessInfo.processInfo.physicalMemory < VBMacDevice.minimumWindowsMemorySize)
        #expect(vm.configuration.hardware.soundDevices.allSatisfy { !$0.enableInput })
        #expect(vm.configuration.qemuSupportState.errors.isEmpty)
    }

    @Test func argumentsDescribeWindowsPlatform() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let arguments = try makeConfiguration(for: vm).arguments()

        #expect(arguments.contains("hvf"))
        #expect(arguments.contains("ramfb"))
        #expect(arguments.contains("tpm-tis-device,tpmdev=tpm0,ppi=off"))
        #expect(arguments.contains("-S"))
        #expect(arguments.contains { $0.hasPrefix("nvme,drive=disk0,serial=VB") && $0.hasSuffix(",bootindex=0") })
        #expect(arguments.contains("\(vm.configuration.hardware.memorySize / .storageMegabyte)M"))
        #expect(!arguments.contains { $0.contains("id=installer") })
    }

    @Test func installerDiskIsAttachedOverNVMeAfterBootDisk() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let arguments = try makeConfiguration(for: vm, installDiskURL: vm.windowsInstallDiskURL).arguments()

        let bootDiskIndex = try #require(arguments.firstIndex { $0.hasPrefix("nvme,drive=disk0") })
        let installerIndex = try #require(arguments.firstIndex(of: "nvme,drive=installer,serial=VBINSTALLER,bootindex=1"))
        #expect(bootDiskIndex < installerIndex)
        #expect(arguments.contains("if=none,id=installer,format=raw,file=\(vm.windowsInstallDiskURL.path),cache=writeback"))
        #expect(!arguments.contains { $0.contains("media=cdrom") })
    }

    @Test func driversDiskIsAttachedOverNVMe() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let arguments = try makeConfiguration(for: vm, driversDiskURL: vm.windowsDriversDiskURL).arguments()

        #expect(arguments.contains("if=none,id=drivers,format=raw,file=\(vm.windowsDriversDiskURL.path),cache=writeback"))
        #expect(arguments.contains("nvme,drive=drivers,serial=VBDRIVERS"))
    }

    @Test func virtioGPUStartsAtConfiguredDisplaySize() throws {
        var vm = try makeWindowsMachine()
        try createBootDisk(for: vm)
        vm.configuration.hardware.displayDevices[0].width = 1600
        vm.configuration.hardware.displayDevices[0].height = 100

        var configuration = makeConfiguration(for: vm)
        configuration.displayAdapter = .virtioGPU
        let arguments = try configuration.arguments()

        #expect(arguments.contains("virtio-gpu-pci,xres=1600,yres=480"))
        #expect(!arguments.contains("ramfb"))
    }

    @Test func commasInPathsAreEscaped() throws {
        let vm = try makeWindowsMachine(named: "Windows, ARM")
        try createBootDisk(for: vm)

        let arguments = try makeConfiguration(for: vm).arguments()

        #expect(arguments.contains { $0.contains("Windows,, ARM.vbvm/EFIVariables.fd") })
        #expect(arguments.contains("Windows,, ARM,debug-threads=on"))
    }

    @Test func nonRawDisksAreRejected() throws {
        var vm = try makeWindowsMachine()
        vm.configuration.hardware.storageDevices[0].backing = .managedImage(
            VBManagedDiskImage(id: "__BOOT__", filename: "Disk", size: 2 * .storageGigabyte, format: .sparse)
        )

        #expect(!vm.configuration.qemuSupportState.errors.isEmpty)
        #expect(throws: (any Error).self) { try makeConfiguration(for: vm).arguments() }
    }

    @Test func bridgedNetworkingIsRejected() throws {
        var vm = try makeWindowsMachine()
        try createBootDisk(for: vm)
        vm.configuration.hardware.networkDevices = [VBNetworkDevice(id: "en0", name: "en0", kind: .bridge)]

        #expect(!vm.configuration.qemuSupportState.errors.isEmpty)
        #expect(throws: (any Error).self) { try makeConfiguration(for: vm).arguments() }
    }

    @Test func networkDeviceUsesConfiguredMACAddress() throws {
        var vm = try makeWindowsMachine()
        try createBootDisk(for: vm)
        vm.configuration.hardware.networkDevices = [VBNetworkDevice(macAddress: "AA:BB:CC:DD:EE:FF")]

        let arguments = try makeConfiguration(for: vm).arguments()

        #expect(arguments.contains("virtio-net-pci,netdev=net0,mac=aa:bb:cc:dd:ee:ff"))
    }

    @Test func installationIsDetectedFromWindowsBootManagerEntry() throws {
        let vm = try makeWindowsMachine()

        try makeVariableStore(bootOptions: ["UiApp", "EFI Internal Shell"]).write(to: vm.windowsEFIVariablesURL)
        #expect(!vm.windowsIsInstalled)

        try makeVariableStore(bootOptions: ["UiApp", "Windows Boot Manager"]).write(to: vm.windowsEFIVariablesURL)
        #expect(vm.windowsIsInstalled)
    }

    @Test func deletedBootOptionsAreIgnored() throws {
        let store = try EFIVariableStore(data: makeVariableStore(bootOptions: ["Windows Boot Manager"], state: 0x3C))

        #expect(store.bootOptionDescriptions.isEmpty)
    }

    @Test(.enabled(if: Homebrew.current.map { FileManager.default.fileExists(atPath: QEMUToolchain(homebrew: $0).firmwareVariablesTemplateURL.path) } ?? false))
    func firmwareVariableTemplateIsReadable() throws {
        let toolchain = QEMUToolchain(homebrew: try #require(Homebrew.current))
        let store = try EFIVariableStore(contentsOf: toolchain.firmwareVariablesTemplateURL)

        #expect(store.bootOptionDescriptions.isEmpty)
    }

    @Test func missingVariableStoreMeansWindowsIsNotInstalled() throws {
        let vm = try makeWindowsMachine()

        #expect(!vm.windowsIsInstalled)
    }

    // MARK: - Helpers

    private func makeWindowsMachine(named name: String = "Windows") throws -> VBVirtualMachine {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QEMULaunchConfigurationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try VBVirtualMachine(creatingWindowsMachineAt: directory.appending(path: "\(name).vbvm", directoryHint: .isDirectory))
    }

    /// Builds an authenticated EDK II variable store with a Boot#### variable for each description.
    private func makeVariableStore(bootOptions: [String], state: UInt8 = 0x3F) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func guid(_ uuid: UUID) -> Data {
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            return Data([bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8..<16])
        }

        let storeSize = 4096
        var data = Data(count: 72)
        data.replaceSubrange(40..<44, with: Data("_FVH".utf8))
        data.replaceSubrange(48..<50, with: le(UInt16(72)))

        data += guid(UUID(uuidString: "AAF32C78-947B-439A-A180-2E144EC37792")!)
        data += le(UInt32(storeSize)) + Data([0x5A, 0xFE]) + Data(count: 6)

        for (index, description) in bootOptions.enumerated() {
            let name = Data(String(format: "Boot%04X", index).utf16.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } } + [0, 0])
            let option = le(UInt32(1)) + le(UInt16(0)) + Data(description.utf16.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } } + [0, 0])

            data += le(UInt16(0x55AA)) + Data([state, 0]) + le(UInt32(7)) + Data(count: 8 + 16 + 4)
            data += le(UInt32(name.count)) + le(UInt32(option.count))
            data += guid(EFIVariableStore.globalVariableVendor)
            data += name + option
            data += Data(count: (4 - data.count % 4) % 4)
        }

        data += Data(repeating: 0xFF, count: 72 + storeSize - data.count)
        return data
    }

    private func createBootDisk(for vm: VBVirtualMachine) throws {
        let url = vm.diskImageURL(for: try vm.bootDiskImage)
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data(count: 4096)))
    }

    private func makeConfiguration(for vm: VBVirtualMachine, installDiskURL: URL? = nil, driversDiskURL: URL? = nil) -> QEMULaunchConfiguration {
        QEMULaunchConfiguration(
            model: vm,
            toolchain: QEMUToolchain(homebrew: Homebrew(prefix: URL(filePath: "/opt/homebrew", directoryHint: .isDirectory))),
            runtimePaths: .init(
                monitorSocket: URL(filePath: "/tmp/vbq-test/qmp.sock"),
                displaySocket: URL(filePath: "/tmp/vbq-test/vnc.sock"),
                tpmSocket: URL(filePath: "/tmp/vbq-test/tpm.sock")
            ),
            installDiskURL: installDiskURL,
            driversDiskURL: driversDiskURL
        )
    }
}
