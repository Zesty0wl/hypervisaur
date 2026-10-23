//
//  ConfigurationModels+Validation.swift
//  VirtualCore
//
//  Created by Guilherme Rambo on 19/07/22.
//

import Cocoa
import UniformTypeIdentifiers
import Virtualization

public extension VBMacConfiguration {
    
    func validate(for model: VBVirtualMachine, skipVirtualizationConfig: Bool) async -> SupportState {
        var tempModel = model
        tempModel.configuration = self

        guard !skipVirtualizationConfig else {
            return hostSupportState
        }

        guard !systemType.runsWithQEMU else {
            return hostSupportState.merged(with: qemuSupportState)
        }

        do {
            let config = try await VMInstance.makeConfiguration(for: tempModel)

            try config.validate()
            
            return hostSupportState
        } catch {
            return hostSupportState.merged(with: .unsupported([error.localizedDescription]))
        }
    }
    
}

public extension VBMacConfiguration {
    /// The state of this configuration for the current host, used to indicate
    /// possible issues the user may have with it, or to prevent unsupported
    /// configurations from being saved.
    var hostSupportState: SupportState {
        var warnings = [String]()
        var errors = [String]()
        
        if !hardware.pointingDevice.kind.isSupportedByHost {
            errors.append("\(hardware.pointingDevice.kind.name) requires macOS 13 or later.")
        }
        if hasSharedFolders, systemType.supportsSharedFolders {
            warnings.append(VBMacConfiguration.fileSharingNotice)
        }
        if hardware.networkDevices.contains(where: { $0.kind == .bridge }), !VBNetworkDevice.appSupportsBridgedNetworking {
            errors.append(VBNetworkDevice.bridgeUnsupportedMessage)
        }
        if provisioningEnabled, provisioningSetup, !VBMacConfiguration.hostSupportsProvisioning {
            warnings.append(VBMacConfiguration.provisioningUnsupportedHostNotice)
        }
        if !hardware.usbDevices.isEmpty, systemType.supportsUSBPassthrough, !VBMacConfiguration.hostSupportsUSBPassthrough {
            warnings.append(VBMacConfiguration.usbPassthroughUnsupportedHostNotice)
        }

        return SupportState(errors: errors, warnings: warnings)
    }

    static let hostSupportsProvisioning: Bool = {
        if #available(macOS 27.0, *) {
            true
        } else {
            false
        }
    }()

    static let rosettaSupported: Bool = {
        VZLinuxRosettaDirectoryShare.availability != VZLinuxRosettaAvailability.notSupported
    }()

    static func rosettaInstalled() -> Bool {
        VZLinuxRosettaDirectoryShare.availability == VZLinuxRosettaAvailability.installed
    }

    static let fileSharingNotice = "File sharing requires the virtual machine to be running macOS 13 or later. For older versions, you can use the standard macOS file sharing feature in System Preferences > Sharing."

    static let provisioningUnsupportedHostNotice = "Skip Setup Assistant requires macOS 27 or later."

    static let hostSupportsUSBPassthrough: Bool = {
        if #available(macOS 27.0, *) {
            true
        } else {
            false
        }
    }()

    static let usbPassthroughUnsupportedHostNotice = "USB device passthrough requires macOS 27 or later."

    static func rosettaSharingNotice() -> String? {
        if rosettaSupported {
            if rosettaInstalled() {
                return nil
            } else {
                return "Rosetta is not installed. Run `softwareupdate --install-rosetta` to install Rosetta."
            }
        } else {
            return "Rosetta for Linux requires the host Mac to be running macOS 13 or later."
        }
    }
}

public extension VBMacConfiguration.SupportState {
    var errors: [String] {
        guard case .unsupported(let errors) = self else {
            return []
        }
        return errors
    }
    
    var warnings: [String] {
        guard case .warnings(let warnings) = self else {
            return []
        }
        return warnings
    }
    
    var allowsSaving: Bool { errors.isEmpty }
    
    init(errors: [String] = [], warnings: [String] = []) {
        if errors.isEmpty {
            if warnings.isEmpty {
                self = .supported
            } else {
                self = .warnings(warnings)
            }
        } else {
            self = .unsupported(errors)
        }
    }
    
    func merged(with other: Self) -> Self {
        Self.init(errors: errors + other.errors, warnings: warnings + other.warnings)
    }
}

public extension VBNetworkDevice {
    static var appSupportsBridgedNetworking: Bool {
        NSApplication.shared.hasEntitlement("com.apple.vm.networking")
    }
    
    static let bridgeUnsupportedMessage = "Bridged network devices are not available in this build of the app."
}

public extension VBDisplayDevice {
    static var automaticallyReconfiguresDisplaySupportedByHost: Bool {
        if #available(macOS 14.0, *) {
            return true
        } else {
            return false
        }
    }
}

public extension VBPointingDevice.Kind {
    var warning: String? {
        guard self == .trackpad else { return nil }
        return "Trackpad is only recognized by VMs running macOS 13 and later."
    }
    
    var error: String? {
        guard !isSupportedByHost else { return nil }
        return "Trackpad requires both host and VM to be on macOS 13 or later."
    }

    var isSupportedByHost: Bool { true }
}

public extension VBKeyboardDevice.Kind {
    var warning: String? {
        guard self != .generic else { return nil }
        return "Mac keyboard is only recognized by VMs running macOS 13 and later."
    }

    var error: String? {
        guard !isSupportedByHost else { return nil }
        return "Mac keyboard requires macOS 14 or later on host and macOS 13 or later on VM."
    }

    var isSupportedByHost: Bool {
        switch self {
        case .generic:
            return true
        case .mac:
            if #available(macOS 14.0, *) {
                return true
            } else {
                return false
            }
        }
    }
}

public extension VBGuestType {
    var isSupportedByHost: Bool {
        switch self {
        case .mac, .linux:
            return true
        case .windows:
            /// Windows for ARM runs with the Hypervisor framework, which can only run guests of the host's architecture.
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        }
    }

    /// Guests that Virtualization can't run are run with QEMU instead.
    var runsWithQEMU: Bool { self == .windows }

    var supportsSharedFolders: Bool { self != .windows }

    var supportsClipboardSharing: Bool { self == .linux }

    var supportsBridgedNetworking: Bool { self != .windows }

    var supportsDisplayConfiguration: Bool { true }

    var supportsSoundInput: Bool { self != .windows }

    var supportsUSBPassthrough: Bool { self != .windows }

    static let supportedByHost: [VBGuestType] = {
        allCases.filter(\.isSupportedByHost)
    }()

    var supportsVirtualTrackpad: Bool { self == .mac }

    var supportsKeyboardCustomization: Bool { self == .mac }

    var supportsDisplayPPI: Bool { self == .mac }

    var supportsAutomaticDisplayConfiguration: Bool { self != .windows }

    var supportsRosettaMount: Bool { self == .linux }

    var supportsStateRestoration: Bool { self == .mac }

    var supportedRestoreImageTypes: Set<UTType> {
        switch self {
        case .mac: return [.ipsw]
        case .linux: return [.iso, .img]
        case .windows: return [.iso]
        }
    }

    var supportsGuestApp: Bool { self == .mac }

    var supportsProvisioning: Bool { self == .mac }

}

public extension VBVirtualMachine {
    var supportsStateRestoration: Bool { configuration.systemType.supportsStateRestoration }
}

public extension UTType {
    static let ipsw = UTType(filenameExtension: "ipsw")!
    static let iso = UTType(filenameExtension: "iso")!
    static let img = UTType(filenameExtension: "img")!
}

public extension VBMacProvisioningConfiguration {
    /// Unlike the soft validations that are implemented by the model itself and designed to be updated and displayed as the user changes data in the UI,
    /// this one actually creates the underlying Virtualization object and uses that to validate against internal requirements which might change between releases.
    func validateWithVirtualization() throws {
        guard #available(macOS 27.0, *) else { return }

        let options = MacOSVirtualMachineConfigurationHelper.createProvisioningOptions(with: self)

        try options.validate()
    }
}
