//
//  VMConfigurationView.swift
//  VirtualBuddy
//
//  Created by Guilherme Rambo on 17/07/22.
//

import SwiftUI
import VirtualCore

extension EnvironmentValues {
    /// Type of guest that's currently being configured in a `VMConfigurationView`.
    @Entry fileprivate(set) var configurationGuestType: VBGuestType = .mac
}

private struct ResolvedRestoreImageKey: EnvironmentKey {
    static let defaultValue: ResolvedRestoreImage? = nil
}

extension EnvironmentValues {
    var resolvedRestoreImage: ResolvedRestoreImage? {
        get { self[ResolvedRestoreImageKey.self] }
        set { self[ResolvedRestoreImageKey.self] = newValue }
    }
}

enum CatalogFeatureID {
    static let fileSharing = "file_sharing"
    static let guestApp = "guest_app"
    static let trackpad = "trackpad"
    static let macKeyboard = "mac_keyboard"
    static let stateRestoration = "state_restoration"
    static let displayResize = "display_resize"
    static let rosettaSharing = "rosetta_sharing"
    static let provisioning = "provisioning"
    static let usbPassthrough = "usb_passthrough"
}

extension ResolvedRestoreImage {
    func feature(id: String) -> ResolvedVirtualizationFeature? {
        features.first { $0.id == id }
    }
}

extension ResolvedFeatureStatus {
    var supportMessage: String? {
        switch self {
        case .supported:
            return nil
        case .warning(let title, let message), .unsupported(let title, let message):
            return title ?? message
        }
    }

    var supportMessageColor: Color {
        switch self {
        case .supported:
            return .secondary
        case .warning:
            return .yellow
        case .unsupported:
            return .red
        }
    }
}

/// A section of the configuration.
enum VMConfigurationSection: String, Identifiable, CaseIterable {
    case bootDisk
    case general
    case display
    case inputAndSound
    case network
    case storage
    case sharing
    case guestApp
    case usbDevices
    case provisioning

    var id: RawValue { rawValue }

    /// The boot disk, which is only set up in the installer, is as wide as the page, and the other sections sit side by side.
    var isFullWidth: Bool { self == .bootDisk }

    /// The column that the section is in, chosen so that the columns are about as tall as each other.
    var isInRightColumn: Bool {
        switch self {
        case .bootDisk, .general, .inputAndSound, .storage, .guestApp: false
        case .display, .network, .sharing, .usbDevices, .provisioning: true
        }
    }
}

/// Configures a virtual machine on a single page, with its sections side by side in two columns, each only as tall as its
/// settings, so that most of the configuration can be seen at once.
struct VMConfigurationView: View {
    @EnvironmentObject private var viewModel: VMConfigurationViewModel

    var initialConfiguration: VBMacConfiguration

    static var labelSpacing: CGFloat { 2 }

    static let sectionSpacing: CGFloat = 20

    private var systemType: VBGuestType { viewModel.config.systemType }

    private var sections: [VMConfigurationSection] {
        VMConfigurationSection.allCases.filter { section in
            switch section {
            case .bootDisk: viewModel.context == .preInstall
            case .general, .inputAndSound, .storage, .network: true
            case .display: systemType.supportsDisplayConfiguration
            case .sharing: systemType.supportsSharedFolders || systemType.supportsClipboardSharing
            case .guestApp: systemType.supportsGuestApp
            case .usbDevices: systemType.supportsUSBPassthrough
            case .provisioning: systemType.supportsProvisioning
            }
        }
    }

    /// Sections that sit side by side, or one that's as wide as the page.
    private enum Row: Identifiable {
        case columns(left: [VMConfigurationSection], right: [VMConfigurationSection])
        case fullWidth(VMConfigurationSection)

        var id: String {
            switch self {
            case .columns(let left, let right): (left + right).map(\.rawValue).joined(separator: "+")
            case .fullWidth(let section): section.rawValue
            }
        }
    }

    private var rows: [Row] {
        var rows = [Row]()
        var sideBySide = [VMConfigurationSection]()

        func addSideBySide() {
            defer { sideBySide.removeAll() }

            /// Sections that would be on their own in one column have the whole width rather than leaving half of the page empty.
            guard sideBySide.contains(where: \.isInRightColumn), sideBySide.contains(where: { !$0.isInRightColumn }) else {
                rows.append(contentsOf: sideBySide.map { .fullWidth($0) })
                return
            }

            rows.append(.columns(
                left: sideBySide.filter { !$0.isInRightColumn },
                right: sideBySide.filter(\.isInRightColumn)
            ))
        }

        for section in sections {
            if section.isFullWidth {
                addSideBySide()
                rows.append(.fullWidth(section))
            } else {
                sideBySide.append(section)
            }
        }
        addSideBySide()

        return rows
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                if viewModel.isLockedBySavedSession {
                    savedSessionNotice
                }

                ForEach(rows) { row in
                    switch row {
                    case .columns(let left, let right):
                        HStack(alignment: .top, spacing: Self.sectionSpacing) {
                            column(left)
                            column(right)
                        }
                    case .fullWidth(let section):
                        self.section(section)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.configurationGuestType, viewModel.config.systemType)
        .environment(\.resolvedRestoreImage, viewModel.resolvedRestoreImage)
    }

    private func column(_ sections: [VMConfigurationSection]) -> some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            ForEach(sections) { section($0) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Sections

    /// A section's settings, set apart from the page around them, with its title above.
    private func section(_ section: VMConfigurationSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(of: section)

            VStack(alignment: .leading, spacing: 6) {
                content(of: section)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .controlGroup()
            .disabled(viewModel.isLockedBySavedSession)
        }
    }

    private func header(of section: VMConfigurationSection) -> some View {
        HStack(spacing: 6) {
            icon(of: section)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(title(of: section))
                .font(.headline)

            Spacer(minLength: 0)

            if section == .display {
                displayConfiguration.presetPicker
                    .disabled(viewModel.isLockedBySavedSession)
            }
        }
        .padding(.horizontal, 2)
        .contextMenu {
            if section == .general {
                Button("Reset Processors and Memory") {
                    viewModel.config.hardware.cpuCount = initialConfiguration.hardware.cpuCount
                    viewModel.config.hardware.memorySize = initialConfiguration.hardware.memorySize
                }
            }
        }
    }

    private var hasInputDevices: Bool { systemType.supportsVirtualTrackpad || systemType.supportsKeyboardCustomization }

    private func title(of section: VMConfigurationSection) -> String {
        switch section {
        case .bootDisk: "Boot Disk"
        case .general: "Processors and Memory"
        case .display: "Display"
        case .inputAndSound: hasInputDevices ? "Input and Sound" : "Sound"
        case .network: "Network"
        case .storage: viewModel.context == .preInstall ? "Additional Storage" : "Storage"
        case .sharing: "Sharing"
        case .guestApp: "Guest App"
        case .usbDevices: "USB Devices"
        case .provisioning: "Skip Setup Assistant"
        }
    }

    @ViewBuilder
    private func icon(of section: VMConfigurationSection) -> some View {
        switch section {
        case .bootDisk: Image(systemName: "internaldrive")
        case .general: Image(systemName: "memorychip")
        case .display: Image(systemName: "display")
        case .inputAndSound: Image(systemName: hasInputDevices ? "keyboard" : "speaker.wave.2")
        case .network: Image(systemName: "network")
        case .storage: Image(systemName: "externaldrive")
        case .sharing: Image(systemName: "folder")
        case .guestApp:
            Image(.guestSymbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 13)
        case .usbDevices: Image(systemName: "cable.connector")
        case .provisioning: Image(systemName: "person.crop.circle")
        }
    }

    @ViewBuilder
    private func content(of section: VMConfigurationSection) -> some View {
        switch section {
        case .bootDisk:
            if let image = (try? viewModel.vm.bootDevice)?.managedImage {
                ManagedDiskImageEditor(image: image, isExistingDiskImage: false, isForBootVolume: true) { image in
                    viewModel.updateBootStorageDevice(with: image)
                }
            } else {
                Text("Something went terribly wrong: VM doesn't have a boot storage device with a managed disk image.")
                    .foregroundColor(.red)
            }
        case .general:
            HardwareConfigurationView(device: $viewModel.config.hardware)
        case .display:
            displayConfiguration
        case .inputAndSound:
            inputAndSound
        case .network:
            NetworkConfigurationView(hardware: $viewModel.config.hardware)
        case .storage:
            StorageConfigurationView(hardware: $viewModel.config.hardware)
                .environmentObject(viewModel)
        case .sharing:
            SharingConfigurationView(configuration: $viewModel.config)
        case .guestApp:
            GuestAppConfigurationView(configuration: $viewModel.config)
        case .usbDevices:
            USBDevicesConfigurationView(hardware: $viewModel.config.hardware)
        case .provisioning:
            ProvisioningConfigurationView(
                configuration: $viewModel.config,
                contextForbidden: viewModel.context != .preInstall && viewModel.vm.hasBootedNonRecoveryAtLeastOnce
            )
        }
    }

    /// The hardware that has few settings of its own, together in one section.
    @ViewBuilder
    private var inputAndSound: some View {
        if systemType.supportsVirtualTrackpad {
            PointingDeviceConfigurationView(hardware: $viewModel.config.hardware)
        }

        if systemType.supportsKeyboardCustomization {
            KeyboardDeviceConfigurationView(hardware: $viewModel.config.hardware)
        }

        if hasInputDevices {
            Divider()
                .padding(.vertical, 4)
        }

        SoundConfigurationView(hardware: $viewModel.config.hardware)
    }

    private var displayConfiguration: DisplayConfigurationView {
        DisplayConfigurationView(
            device: $viewModel.config.hardware.displayDevices[0],
            selectedPreset: $viewModel.selectedDisplayPreset,
            canChangePPI: systemType.supportsDisplayPPI,
            canReconfigureAutomatically: systemType.supportsAutomaticDisplayConfiguration
        )
    }

    @ViewBuilder
    private var savedSessionNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Resume and shut down this VM to change its hardware.", systemImage: "lock.fill")
                .font(.headline)

            Text("This virtual machine has a saved session, which only works with the hardware it was saved with. You can also discard the saved session to unlock these settings.")
                .foregroundStyle(.secondary)

            Button("Discard Saved Session…", role: .destructive) {
                Task { @MainActor in
                    guard await SavedSessionPrompts.confirmDiscard(name: viewModel.vmName, startsAfterwards: false, from: nil) else { return }

                    do {
                        try await viewModel.discardSavedSession()
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Copies the settings of another virtual machine in the library, chosen from a menu.
struct VMConfigurationTemplatePicker: View {
    let controller: VMTemplatesController
    let context: VMConfigurationContext
    @Binding var configuration: VBMacConfiguration
    var onApply: (_ configuration: VBMacConfiguration) -> ()

    var templates: [VBConfigurationTemplate] {
        switch configuration.systemType {
        case .mac: controller.templatesForMacGuest
        case .linux: controller.templatesForLinuxGuest
        case .windows: controller.templatesForWindowsGuest
        }
    }

    var body: some View {
        Menu("Copy Settings From") {
            ForEach(templates) { template in
                Button(template.name) {
                    apply(template)
                }
            }
        }
        .fixedSize()
        .help("Use the settings of another virtual machine in the library.")
    }

    private func apply(_ template: VBConfigurationTemplate) {
        do {
            var updatedConfiguration = configuration
            try updatedConfiguration.apply(
                template: template,
                includingStorageDevices: context == .preInstall
            )

            configuration = updatedConfiguration

            onApply(updatedConfiguration)
        } catch {
            NSApp.presentError(error)
        }
    }
}

#if DEBUG
struct VMConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationSheet_Previews.previews
    }
}
#endif


