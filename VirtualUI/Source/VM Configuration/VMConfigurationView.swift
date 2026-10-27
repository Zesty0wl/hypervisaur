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

/// A page of the configuration, listed in its sidebar.
enum VMConfigurationPage: String, Identifiable, CaseIterable {
    case bootDisk
    case general
    case storage
    case display
    case network
    case sharing
    case guestApp
    case usbDevices
    case provisioning

    var id: RawValue { rawValue }
}

/// Configures a virtual machine with a sidebar of pages, each with a summary of its settings, beside the selected page,
/// so that the whole configuration fits on a screen without scrolling.
struct VMConfigurationView: View {
    @EnvironmentObject private var viewModel: VMConfigurationViewModel

    var initialConfiguration: VBMacConfiguration

    static var labelSpacing: CGFloat { 2 }

    static let sidebarWidth: CGFloat = 230

    @AppStorage("config.selectedPage")
    private var storedSelection = VMConfigurationPage.general

    private var systemType: VBGuestType { viewModel.config.systemType }

    private var pages: [VMConfigurationPage] {
        VMConfigurationPage.allCases.filter { page in
            switch page {
            case .bootDisk: viewModel.context == .preInstall
            case .general, .storage, .network: true
            case .display: systemType.supportsDisplayConfiguration
            case .sharing: systemType.supportsSharedFolders || systemType.supportsClipboardSharing
            case .guestApp: systemType.supportsGuestApp
            case .usbDevices: systemType.supportsUSBPassthrough
            case .provisioning: systemType.supportsProvisioning
            }
        }
    }

    /// The page that was last looked at, or the first one when that page isn't available for this virtual machine.
    private var selection: Binding<VMConfigurationPage?> {
        Binding {
            pages.contains(storedSelection) ? storedSelection : pages.first
        } set: { newValue in
            if let newValue { storedSelection = newValue }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)

            Divider()

            if let page = selection.wrappedValue {
                detail(for: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(page)
            }
        }
        .environment(\.configurationGuestType, viewModel.config.systemType)
        .environment(\.resolvedRestoreImage, viewModel.resolvedRestoreImage)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(pages) { page in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(of: page))

                        if let summary = summary(of: page) {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    icon(of: page)
                }
                .padding(.vertical, 3)
                .tag(page)
                .contextMenu {
                    if page == .general {
                        Button("Reset General Settings") {
                            viewModel.config.hardware.cpuCount = initialConfiguration.hardware.cpuCount
                            viewModel.config.hardware.memorySize = initialConfiguration.hardware.memorySize
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func title(of page: VMConfigurationPage) -> String {
        switch page {
        case .bootDisk: "Boot Disk"
        case .general: "General"
        case .storage: viewModel.context == .preInstall ? "Additional Storage" : "Storage"
        case .display: "Display"
        case .network: "Network"
        case .sharing: "Sharing"
        case .guestApp: "Guest App"
        case .usbDevices: "USB Devices"
        case .provisioning: "Skip Setup Assistant"
        }
    }

    private func summary(of page: VMConfigurationPage) -> String? {
        let config = viewModel.config

        switch page {
        case .bootDisk: return nil
        case .general: return config.generalSummary
        case .storage:
            if viewModel.context == .preInstall {
                return config.hardware.storageDevices.count == 1 ? "None" : config.storageSummary
            }
            return config.storageSummary
        case .display: return config.displaySummary
        case .network: return config.networkSummary
        case .sharing: return config.sharingSummary
        case .guestApp: return config.guestAppSummary(for: viewModel.resolvedRestoreImage?.version)
        case .usbDevices: return config.usbDevicesSummary
        case .provisioning: return config.provisioningSummary
        }
    }

    @ViewBuilder
    private func icon(of page: VMConfigurationPage) -> some View {
        switch page {
        case .bootDisk: Image(systemName: "internaldrive")
        case .general: Image(systemName: "memorychip")
        case .storage: Image(systemName: "externaldrive")
        case .display: Image(systemName: "display")
        case .network: Image(systemName: "network")
        case .sharing: Image(systemName: "folder")
        case .guestApp:
            Image(.guestSymbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 15)
        case .usbDevices: Image(systemName: "cable.connector")
        case .provisioning: Image(systemName: "person.crop.circle")
        }
    }

    // MARK: Detail

    private func detail(for page: VMConfigurationPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                icon(of: page)
                    .font(.system(size: 20))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: page))
                        .font(.title2.weight(.semibold))

                    if let summary = summary(of: page) {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Spacer()

                if page == .display {
                    displayConfiguration.presetPicker
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.isLockedBySavedSession {
                        savedSessionNotice
                    }

                    content(of: page)
                        .disabled(viewModel.isLockedBySavedSession)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func content(of page: VMConfigurationPage) -> some View {
        switch page {
        case .bootDisk:
            group {
                if let image = (try? viewModel.vm.bootDevice)?.managedImage {
                    ManagedDiskImageEditor(image: image, isExistingDiskImage: false, isForBootVolume: true) { image in
                        viewModel.updateBootStorageDevice(with: image)
                    }
                } else {
                    Text("Something went terribly wrong: VM doesn't have a boot storage device with a managed disk image.")
                        .foregroundColor(.red)
                }
            }
        case .general:
            general
        case .storage:
            group {
                StorageConfigurationView(hardware: $viewModel.config.hardware)
                    .environmentObject(viewModel)
            }
        case .display:
            group { displayConfiguration }
        case .network:
            group { NetworkConfigurationView(hardware: $viewModel.config.hardware) }
        case .sharing:
            group { SharingConfigurationView(configuration: $viewModel.config) }
        case .guestApp:
            group { GuestAppConfigurationView(configuration: $viewModel.config) }
        case .usbDevices:
            group { USBDevicesConfigurationView(hardware: $viewModel.config.hardware) }
        case .provisioning:
            group {
                ProvisioningConfigurationView(
                    configuration: $viewModel.config,
                    contextForbidden: viewModel.context != .preInstall && viewModel.vm.hasBootedNonRecoveryAtLeastOnce
                )
            }
        }
    }

    /// The hardware that has few settings of its own, together on one page.
    @ViewBuilder
    private var general: some View {
        group("Processors and Memory") {
            HardwareConfigurationView(device: $viewModel.config.hardware)
        }

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
            if systemType.supportsVirtualTrackpad {
                group("Pointing Device") {
                    PointingDeviceConfigurationView(hardware: $viewModel.config.hardware)
                }
            }

            if systemType.supportsKeyboardCustomization {
                group("Keyboard") {
                    KeyboardDeviceConfigurationView(hardware: $viewModel.config.hardware)
                }
            }

            group("Sound") {
                SoundConfigurationView(hardware: $viewModel.config.hardware)
            }
        }
    }

    private var displayConfiguration: DisplayConfigurationView {
        DisplayConfigurationView(
            device: $viewModel.config.hardware.displayDevices[0],
            selectedPreset: $viewModel.selectedDisplayPreset,
            canChangePPI: systemType.supportsDisplayPPI,
            canReconfigureAutomatically: systemType.supportsAutomaticDisplayConfiguration
        )
    }

    /// Settings that belong together, set apart from the page around them, with an optional title above.
    private func group<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .controlGroup()
        }
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
