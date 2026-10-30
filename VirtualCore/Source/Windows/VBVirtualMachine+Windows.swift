import Foundation

public extension VBManagedDiskImage {
    static let defaultWindowsBootDiskImageSize: UInt64 = 80 * .storageGigabyte

    /// QEMU reads raw images, so Windows virtual machines always use that format for the boot disk.
    static var managedWindowsBootImage: VBManagedDiskImage {
        VBManagedDiskImage(
            id: "__BOOT__",
            filename: "Disk",
            size: defaultWindowsBootDiskImageSize,
            format: .raw
        )
    }
}

public extension VBDisplayDevice {
    /// The resolution Windows uses once its display driver is installed. Windows Setup uses a fixed size that the firmware chooses.
    static let windowsDisplay = VBDisplayDevice(name: "Display", width: 1280, height: 800, pixelsPerInch: 72)
}

public extension VBMacDevice {
    static let minimumWindowsMemorySize: UInt64 = 4 * .storageGigabyte

    static var defaultWindows: VBMacDevice {
        var hardware = VBMacDevice.default

        hardware.memorySize = Swift.min(
            Swift.max(hardware.memorySize, minimumWindowsMemorySize),
            ProcessInfo.processInfo.physicalMemory
        )
        hardware.displayDevices = [.windowsDisplay]
        hardware.storageDevices = [
            VBStorageDevice(
                isBootVolume: true,
                isReadOnly: false,
                isUSBMassStorageDevice: false,
                backing: .managedImage(.managedWindowsBootImage)
            )
        ]
        hardware.soundDevices = [VBSoundDevice(enableOutput: true, enableInput: false)]

        return hardware
    }
}

public extension VBVirtualMachine {
    init(creatingWindowsMachineAt bundleURL: URL) throws {
        try self.init(bundleURL: bundleURL, isNewInstall: true)

        configuration = VBMacConfiguration(systemType: .windows, hardware: .defaultWindows, guestAdditionsEnabled: false)
        metadata.backgroundHash = .virtualBuddyBackgroundWindows

        try saveMetadata()
    }

    /// UEFI variables for the virtual machine's firmware.
    var windowsEFIVariablesURL: URL { bundleURL.appending(path: "EFIVariables.fd") }

    /// Persistent state for the virtual machine's TPM.
    var windowsTPMStateURL: URL { bundleURL.appending(path: "TPM", directoryHint: .isDirectory) }

    /// The copy of the Windows installer that's attached while Windows is being installed. See ``WindowsInstallDisk``.
    var windowsInstallDiskURL: URL { bundleURL.appending(path: "Installer.img") }

    /// The disk with the Windows drivers. See ``WindowsDriversDisk``.
    var windowsDriversDiskURL: URL { bundleURL.appending(path: "Drivers.img") }

    /// The version of the drivers on the drivers disk, so that it's only recreated when they change.
    var windowsDriversDiskVersionURL: URL { metadataDirectoryURL.appending(path: "DriversDisk.version") }

    /// Present once Windows Setup has run with the drivers disk attached, which installs the display driver,
    /// so that the virtio GPU can be used instead of the framebuffer that doesn't need one.
    var windowsGuestDriversMarkerURL: URL { metadataDirectoryURL.appending(path: "GuestDrivers.installed") }

    var windowsGuestDriversInstalled: Bool { FileManager.default.fileExists(atPath: windowsGuestDriversMarkerURL.path) }

    var qemuLogURL: URL { metadataDirectoryURL.appending(path: "qemu.log") }

    var swtpmLogURL: URL { metadataDirectoryURL.appending(path: "swtpm.log") }

    var networkLogURL: URL { metadataDirectoryURL.appending(path: "network.log") }

    static let windowsBootManagerDescription = "Windows Boot Manager"

    /// Windows Setup adds its boot manager to the firmware's boot options once Windows has been copied to the disk,
    /// which is how VirtualBuddy tells that the installer is no longer needed.
    var windowsIsInstalled: Bool {
        guard let store = try? EFIVariableStore(contentsOf: windowsEFIVariablesURL) else { return false }
        return store.bootOptionDescriptions.contains(Self.windowsBootManagerDescription)
    }
}
