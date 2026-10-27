//
//  StorageConfigurationView.swift
//  VirtualUI
//
//  Created by Guilherme Rambo on 19/07/22.
//

import SwiftUI
import VirtualCore

struct StorageConfigurationView: View {
    @EnvironmentObject var viewModel: VMConfigurationViewModel

    @Binding var hardware: VBMacDevice

    @State private var isShowingDeviceConfigurationSheet = false
    @State private var deviceBeingConfigured: VBStorageDevice?

    private var hideBootDisk: Bool { viewModel.context == .preInstall }

    private func shouldHide(_ device: VBStorageDevice) -> Bool {
        if hideBootDisk {
            return device.isBootVolume
        } else {
            return false
        }
    }

    @State private var isCopyingDiskImages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            list

            if viewModel.context == .postInstall, viewModel.hasExternalDiskImages {
                externalDiskImagesNotice
            }
        }
    }

    @ViewBuilder
    private var externalDiskImagesNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Some disk images are stored outside of this virtual machine. Its session can’t be saved until they’re copied into it. The originals are not changed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                copyExternalDiskImages()
            } label: {
                if isCopyingDiskImages {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Copy into Virtual Machine…")
                }
            }
            .disabled(isCopyingDiskImages)
        }
    }

    private func copyExternalDiskImages() {
        Task { @MainActor in
            let confirmed = await NSAlert.runConfirmationAlert(
                title: "Copy Disk Images Into the Virtual Machine?",
                message: "The disk images stored outside of this virtual machine are copied into it. The originals are not changed, and nothing is modified if copying fails. This can take a while and use a lot of disk space on volumes that don’t support cloning.",
                continueButtonTitle: "Copy",
                cancelButtonTitle: "Cancel"
            )
            guard confirmed else { return }

            isCopyingDiskImages = true
            defer { isCopyingDiskImages = false }

            do {
                try await viewModel.copyExternalDiskImagesIntoVirtualMachine()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private var visibleDevices: [Binding<VBStorageDevice>] {
        $hardware.storageDevices.filter { !shouldHide($0.wrappedValue) }
    }

    private var list: some View {
        CompactList(isEmpty: visibleDevices.isEmpty, emptyMessage: "No additional storage devices.") {
            ForEach(visibleDevices) { $device in
                StorageDeviceListItem(device: $device) {
                    configure(device)
                } remove: {
                    remove(device)
                }
            }
        } addButton: {
            Button {
                create()
            } label: {
                Label("Add Storage Device…", systemImage: "plus")
            }
        }
        .sheet(isPresented: $isShowingDeviceConfigurationSheet) {
            let device = deviceBeingConfigured ?? .template
            let isNewDevice = deviceBeingConfigured == nil

            StorageDeviceDetailView(device: device, isNewDevice: isNewDevice, onSave: { updatedDevice in
                if isNewDevice {
                    try await createImageIfNeeded(for: updatedDevice)
                }
                
                hardware.addOrUpdate(updatedDevice)
            })
            .environmentObject(viewModel)
            .padding()
            .frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity)
        }
    }

    private func configure(_ device: VBStorageDevice?) {
        deviceBeingConfigured = device
        isShowingDeviceConfigurationSheet = true
    }
    
    private func create() {
        configure(nil)
    }

    private func remove(_ device: VBStorageDevice) {
        guard !device.isBootVolume else { return }
        hardware.storageDevices.removeAll { $0.id == device.id }
    }
    
    private func createImageIfNeeded(for newDevice: VBStorageDevice) async throws {
        guard newDevice.usesManagedDiskImage else { return }
        
        try await viewModel.createImage(for: newDevice)
    }
}

struct StorageDeviceListItem: View {
    @Binding var device: VBStorageDevice
    var configureDevice: () -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle(device.displayName, isOn: $device.isEnabled)
                .labelsHidden()
                .disabled(device.isBootVolume)
                .help(device.isBootVolume ? "The boot storage device can't be disabled" : "Enable/disable this storage device")

            device.iconView

            Text(device.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(device.isEnabled ? 1 : 0.6)

            Spacer(minLength: 0)

            Button {
                configureDevice()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Device settings")
            .buttonStyle(.borderless)
            .disabled(device.isBootVolume && !device.canBeResized)

            if !device.isBootVolume {
                CompactListRemoveButton(help: "Remove this storage device", action: remove)
            }
        }
        .compactListRow()
        .contextMenu {
            Button("Device Settings…", action: configureDevice)
                .disabled(device.isBootVolume && !device.canBeResized)

            if !device.isBootVolume {
                Button("Remove", action: remove)
            }
        }
    }
}

extension VBStorageDevice {
    var icon: Image {
        if isUSBMassStorageDevice {
            return Image(systemName: "externaldrive.fill")
        } else if isBootVolume {
            return Image(systemName: "wrench.and.screwdriver.fill")
        } else {
            return Image(systemName: "internaldrive.fill")
        }
    }

    @ViewBuilder
    var iconView: some View {
        icon
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: 16)
        .symbolRenderingMode(.hierarchical)
    }
}

#if DEBUG
struct StorageConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        _ConfigurationSectionPreview { StorageConfigurationView(hardware: $0.hardware) }
            .environmentObject(VMConfigurationViewModel(.preview))
    }
}
#endif
