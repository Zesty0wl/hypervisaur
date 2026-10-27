//
//  ConfigurationModels+Summary.swift
//  VirtualCore
//
//  Created by Guilherme Rambo on 19/07/22.
//

import Foundation

public extension VBMacConfiguration {

    var generalSummary: String {
        "\(hardware.cpuCount) CPUs / \(hardware.memorySize / 1024 / 1024 / 1024) GB"
    }

    var provisioningSummary: String {
        if provisioningEnabled {
            if provisioningSetup {
                "Enabled"
            } else {
                "Not Set Up"
            }
        } else {
            "Disabled"
        }
    }

    var storageSummary: String {
        if hardware.storageDevices.count > 1 {
            return "\(hardware.storageDevices.count) Devices"
        } else {
            return "Boot Only"
        }
    }

    var displaySummary: String {
        guard let display = hardware.displayDevices.first else { return "No Displays" }
        return "\(display.width)x\(display.height)x\(display.pixelsPerInch)"
    }

    var soundSummary: String {
        guard let sound = hardware.soundDevices.first else { return "No Sound" }
        return sound.enableInput ? "Input / Output" : "Output Only"
    }

    var sharingSummary: String {
        var items = [String]()

        switch sharedFolders.count {
        case 0: break
        case 1: items.append("One Folder")
        default: items.append("\(sharedFolders.count) Folders")
        }

        if systemType.supportsClipboardSharing, clipboardSharingEnabled {
            items.append("Clipboard")
        }

        return items.isEmpty ? "None" : items.joined(separator: ", ")
    }

    var networkSummary: String {
        guard let network = hardware.networkDevices.first else { return "No Network" }
        return network.kind.name
    }

    var usbDevicesSummary: String {
        switch hardware.usbDevices.count {
        case 0: "None"
        case 1: "One Device"
        default: "\(hardware.usbDevices.count) Devices"
        }
    }
    
    var pointingDeviceSummary: String { hardware.pointingDevice.kind.name }

    var keyboardDeviceSummary: String { hardware.keyboardDevice.kind.name }

    @MainActor func guestAppSummary(for guestVersion: SoftwareVersion?) -> String {
        let support = guestAppSupport(for: guestVersion)
        if support == .unsupported { return "Not Supported" }
        guard guestAdditionsEnabled else { return "Disabled" }
        return support == .sharedFoldersOnly ? "Shared Folders Only" : "Enabled"
    }

}
