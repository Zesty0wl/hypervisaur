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

    @Test func driversDiskIsARemovableUSBDrive() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let arguments = try makeConfiguration(for: vm, driversDiskURL: vm.windowsDriversDiskURL).arguments()

        #expect(arguments.contains("if=none,id=drivers,format=raw,file=\(vm.windowsDriversDiskURL.path),readonly=on"))
        #expect(arguments.contains("usb-storage,bus=xhci.0,drive=drivers,removable=on"))
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

    @Test func guestAgentPortIsServedOnASocket() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let arguments = try makeConfiguration(for: vm).arguments()

        #expect(arguments.contains("socket,id=vbagent,path=/tmp/vbq-test/agent.sock,server=on,wait=off"))
        #expect(arguments.contains("virtserialport,bus=vbserial.0,chardev=vbagent,name=hypervisaur.agent"))
    }

    @Test(arguments: [true, false])
    func clipboardIsSharedThroughTheSPICEAgentPort(enabled: Bool) throws {
        var vm = try makeWindowsMachine()
        try createBootDisk(for: vm)
        vm.configuration.clipboardSharingEnabled = enabled

        let arguments = try makeConfiguration(for: vm).arguments()

        #expect(arguments.contains("qemu-vdagent,id=vdagent,clipboard=on") == enabled)
        #expect(arguments.contains("virtserialport,bus=vbserial.0,chardev=vdagent,name=com.redhat.spice.0") == enabled)
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

    // MARK: - Saved Sessions

    @Test func bootingNamesTheSoundDeviceSoThatItCanBeUnpluggedForSaving() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)
        try #require(QEMULaunchConfiguration.hasSoundDevice(vm))

        let arguments = try makeConfiguration(for: vm).arguments()

        #expect(arguments.contains("usb-audio,id=\(QEMULaunchConfiguration.soundDeviceID),bus=xhci.0,audiodev=audio0"))
        #expect(!arguments.contains("-incoming"))
        #expect(arguments.contains(QEMULaunchConfiguration.defaultMachineType))
    }

    @Test func restoringWaitsForTheStateWithThePinnedMachineTypeAndTheDevicesItBootsWith() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)
        try #require(QEMULaunchConfiguration.hasSoundDevice(vm))

        var configuration = makeConfiguration(for: vm, driversDiskURL: vm.windowsDriversDiskURL)
        let booting = try configuration.arguments()
        configuration.machineType = "virt-11.1"
        configuration.restoresSavedState = true
        let arguments = try configuration.arguments()

        let machineIndex = try #require(arguments.firstIndex(of: "-machine"))
        #expect(arguments[machineIndex + 1] == "virt-11.1")
        #expect(Array(arguments.suffix(2)) == ["-incoming", "defer"])

        /// QEMU puts a USB hub on the last free port, so the USB devices have to be the same as when booting, sound
        /// device included, to end up on the same ports. The sound device is unplugged before the state is loaded.
        let usbDevices = { (arguments: [String]) in arguments.filter { $0.contains("bus=xhci.0") } }
        #expect(usbDevices(arguments) == usbDevices(booting))
        #expect(arguments.contains("usb-audio,id=\(QEMULaunchConfiguration.soundDeviceID),bus=xhci.0,audiodev=audio0"))
    }

    @Test func comparableArgumentsIgnoreWhatMayChangeBetweenRuns() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        /// The same virtual machine somewhere else, with a different name that needs escaping in QEMU's options, restored
        /// with the configuration that was saved with its session.
        let movedURL = vm.bundleURL.deletingLastPathComponent().appending(path: "Renamed, Moved.vbvm", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: vm.bundleURL, to: movedURL)
        var moved = try VBVirtualMachine(bundleURL: movedURL)
        moved.configuration = try PropertyListDecoder().decode(VBMacConfiguration.self, from: PropertyListEncoder().encode(vm.configuration))

        var restoring = makeConfiguration(for: moved)
        restoring.runtimePaths.monitorSocket = URL(filePath: "/tmp/vbq-other/qmp.sock")
        restoring.machineType = "virt-11.1"
        restoring.restoresSavedState = true

        let saved = try makeConfiguration(for: vm).comparableArguments()

        #expect(try restoring.comparableArguments() == saved)
        #expect(!saved.contains { $0.contains(vm.bundleURL.path) || $0.contains("/tmp/vbq-test") })
    }

    @Test func comparableArgumentsChangeWithTheHardware() throws {
        var vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let before = try makeConfiguration(for: vm).comparableArguments()
        vm.configuration.hardware.cpuCount += 1

        #expect(try makeConfiguration(for: vm).comparableArguments() != before)
    }

    /// Each network device is connected to Hypervisaur's network for it, which serves the shared folders itself.
    @Test func networkDevicesConnectToHypervisaursNetworks() throws {
        var vm = try makeWindowsMachine()
        try createBootDisk(for: vm)
        vm.configuration.hardware.networkDevices = [VBNetworkDevice(macAddress: "AA:BB:CC:DD:EE:01"), VBNetworkDevice(macAddress: "AA:BB:CC:DD:EE:02")]

        var configuration = makeConfiguration(for: vm)
        configuration.folderSharing = WindowsFolderSharing(
            directoryURL: URL(filePath: "/tmp/vbq-test/samba", directoryHint: .isDirectory),
            serverURL: URL(filePath: "/opt/homebrew/sbin/samba-dot-org-smbd"),
            password: "secret",
            shares: []
        )

        let arguments = try configuration.arguments()

        #expect(arguments.contains("stream,id=net0,server=off,addr.type=unix,addr.path=/tmp/vbq-test/net0.sock"))
        #expect(arguments.contains("stream,id=net1,server=off,addr.type=unix,addr.path=/tmp/vbq-test/net1.sock"))
        #expect(!arguments.contains { $0.hasPrefix("user,") || $0.contains("guestfwd") })
    }

    /// A session saved with QEMU's own network can only be restored with it, so it isn't the same as one saved with Hypervisaur's.
    @Test func comparableArgumentsDependOnTheNetwork() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        var qemuNetwork = makeConfiguration(for: vm)
        qemuNetwork.network = .qemu

        #expect(try qemuNetwork.comparableArguments().contains("user,id=net0"))
        #expect(try qemuNetwork.comparableArguments() != makeConfiguration(for: vm).comparableArguments())
    }

    @Test func displayIsServedOverDBusAndInputGoesThroughVNC() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let arguments = try makeConfiguration(for: vm).arguments()

        #expect(arguments.contains(["-display", "dbus,p2p=yes"]))
        #expect(arguments.contains(["-vnc", "unix:/tmp/vbq-test/vnc.sock"]))
    }

    @Test func comparableArgumentsLeaveOutTheDisplayAndInputConnections() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let comparable = try makeConfiguration(for: vm).comparableArguments()

        #expect(!comparable.contains("-display"))
        #expect(!comparable.contains("-vnc"))
    }

    @Test func sessionsSavedWhenTheDisplayWentThroughVNCCompareTheSame() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        let comparable = try makeConfiguration(for: vm).comparableArguments()
        let qmpIndex = try #require(comparable.firstIndex(of: "-qmp"))

        var savedEarlier = comparable
        savedEarlier.insert(contentsOf: ["-display", "none", "-vnc", "unix:/$RUNTIME/vnc.sock"], at: qmpIndex)

        #expect(QEMULaunchConfiguration.withoutConnections(savedEarlier) == comparable)
    }

    @Test func qemusNetworkRunsSambaForTheFirstNetworkDevice() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        var configuration = makeConfiguration(for: vm)
        configuration.network = .qemu
        configuration.folderSharing = WindowsFolderSharing(
            directoryURL: URL(filePath: "/tmp/vbq-test,1/samba", directoryHint: .isDirectory),
            serverURL: URL(filePath: "/opt/homebrew/sbin/samba-dot-org-smbd"),
            password: "secret",
            shares: []
        )

        let arguments = try configuration.arguments()

        #expect(arguments.contains("user,id=net0,guestfwd=tcp:10.0.2.4:445-cmd:'/opt/homebrew/sbin/samba-dot-org-smbd' '--configfile=/tmp/vbq-test,,1/samba/smb.conf'"))
    }

    /// Folders can be shared or not when a saved session is restored, since QEMU doesn't save anything about the server.
    @Test func comparableArgumentsIgnoreSharedFolders() throws {
        let vm = try makeWindowsMachine()
        try createBootDisk(for: vm)

        var sharing = makeConfiguration(for: vm)
        sharing.folderSharing = WindowsFolderSharing(
            directoryURL: URL(filePath: "/tmp/vbq-test/samba", directoryHint: .isDirectory),
            serverURL: URL(filePath: "/opt/homebrew/sbin/samba-dot-org-smbd"),
            password: "secret",
            shares: []
        )

        #expect(try sharing.comparableArguments() == makeConfiguration(for: vm).comparableArguments())
    }

    @Test func windowsSessionsCanBeSaved() throws {
        let vm = try makeWindowsMachine()

        let eligibility = SavedSessionEligibility.evaluate(model: vm, options: .default, supportsCloning: true)

        #expect(!eligibility.issues.contains(.unsupportedGuest))
        #expect(eligibility.isApplicable)
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
                vncSocket: URL(filePath: "/tmp/vbq-test/vnc.sock"),
                tpmSocket: URL(filePath: "/tmp/vbq-test/tpm.sock"),
                agentSocket: URL(filePath: "/tmp/vbq-test/agent.sock"),
                networkSocketsDirectory: URL(filePath: "/tmp/vbq-test", directoryHint: .isDirectory)
            ),
            installDiskURL: installDiskURL,
            driversDiskURL: driversDiskURL
        )
    }
}
