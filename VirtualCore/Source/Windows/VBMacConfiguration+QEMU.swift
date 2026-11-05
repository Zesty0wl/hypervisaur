import Foundation

public extension VBMacConfiguration {
    /// Problems with the configuration that would prevent QEMU from running the virtual machine.
    var qemuSupportState: SupportState {
        var errors = [String]()
        var warnings = [String]()

        for device in hardware.storageDevices where device.isEnabled {
            switch device.backing {
            case .managedImage(let image):
                if image.format != .raw {
                    errors.append("The disk image “\(device.displayName)” uses the \(image.format.displayName) format. Windows virtual machines can only use raw disk images.")
                }
            case .customImage(let url):
                if url.pathExtension.lowercased() != VBManagedDiskImage.Format.raw.fileExtension {
                    warnings.append("The disk image “\(device.displayName)” must be a raw disk image to be used with Windows.")
                }
            }
        }

        if hardware.memorySize < VBMacDevice.minimumWindowsMemorySize {
            warnings.append("Windows 11 requires at least 4 GB of memory.")
        }

        if hardware.soundDevices.contains(where: \.enableInput) {
            warnings.append("Audio input isn’t available for Windows virtual machines.")
        }

        if hasSharedFolders, !hasWindowsFolderSharingNetwork {
            warnings.append(Self.windowsSharedFoldersNeedNetworkNotice)
        }

        if !hardware.usbDevices.isEmpty {
            warnings.append("USB device passthrough isn’t available for Windows virtual machines.")
        }

        return SupportState(errors: errors, warnings: warnings)
    }

    static let windowsSharedFoldersNeedNetworkNotice = "Windows reaches shared folders over the network, so they need a network device."

    /// Whether Windows can reach the shared folders: through the first NAT device's network, or through the folder sharing
    /// network that a virtual machine whose devices are all bridged has. See ``QEMULaunchConfiguration/hasFolderSharingNetwork(_:)``.
    var hasWindowsFolderSharingNetwork: Bool {
        hardware.networkDevices.contains { $0.kind == .NAT } || QEMULaunchConfiguration.hasFolderSharingNetwork(hardware)
    }
}
