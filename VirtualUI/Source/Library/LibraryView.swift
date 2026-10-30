//
//  LibraryView.swift
//  VirtualBuddy
//
//  Created by Guilherme Rambo on 10/04/22.
//

import SwiftUI
import VirtualCore

public extension String {
    static let vb_libraryWindowID = "library"
}

private extension UserDefaults {
    /// Not using `AppStorage` because this can't update the view.
    var hasSeenFirstLaunchExperience: Bool {
        get { bool(forKey: #function) }
        set {
            set(newValue, forKey: #function)
            synchronize()
        }
    }
}

public struct LibraryView: View {
    @ObservedObject private var settingsContainer = VBSettingsContainer.current

    @EnvironmentObject private var library: VMLibraryController
    @EnvironmentObject private var sessionManager: VirtualMachineSessionUIManager

    @Environment(\.openVirtualBuddySettings)
    private var openSettings

    /// Whether the first launch experience has been presented in the current app session.
    /// The defaults flag itself is not read again, but this is set whenever a non-empty library state is shown.
    @State private var canShowFirstLaunchExperience = true

    /// Previews of running virtual machines are only taken while somebody can see them.
    @State private var isLibraryVisible = false

    private var shouldShowFirstLaunchExperienceOnEmptyLibrary: Bool {
        guard #available(macOS 15.0, *) else { return false }
        return canShowFirstLaunchExperience && (!hasSeenFirstLaunchExperience || UserDefaults.standard.bool(forKey: "VBForceFirstLaunchExperience"))
    }

    /// Set on view initialization only so that when the defaults flag is updated, it doesn't cause the first launch experience to disappear.
    private let hasSeenFirstLaunchExperience: Bool

    public init() {
        hasSeenFirstLaunchExperience = UserDefaults.standard.hasSeenFirstLaunchExperience
    }

    public var body: some View {
        libraryContents
            .frame(minWidth: 1000, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
            /// The rack looks the same in light and dark mode, like hardware does, so the window around it stays dark.
            .windowAppearance(.darkAqua)
            .task {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "VBOpenSettings") {
                    openSettings()
                }
                #endif
            }
    }

    private static let unitSpacing: CGFloat = 4
    private static let rackPadding: CGFloat = 14

    @ViewBuilder
    private var libraryContents: some View {
        ZStack {
            RackPalette.caseBackground
                .ignoresSafeArea()

            /// Units slide along the rails as the rack scrolls, and the rails show wherever there's no unit.
            RackRails(holePitch: (LibraryItemView.height + Self.unitSpacing) / 3)
                .padding(.horizontal, Self.rackPadding)
                .ignoresSafeArea()

            Group {
                switch library.state {
                case .loaded(let machines):
                    rack(machines)
                        .task { canShowFirstLaunchExperience = false }
                case .empty:
                    if shouldShowFirstLaunchExperienceOnEmptyLibrary {
                        FirstLaunchExperienceView {
                            sessionManager.launchInstallWizard(library: library)
                        }
                        .task { UserDefaults.standard.hasSeenFirstLaunchExperience = true }
                    } else {
                        libraryEmptyMessage
                    }
                case .loading:
                    EmptyView()
                case .volumeNotMounted:
                    libraryVolumeNotMountedMessage
                case .directoryMissing:
                    libraryDirectoryMissingMessage
                }
            }
            .transition(.scale(scale: 1.5).combined(with: .opacity))
        }
        .animation(.snappy, value: library.state.id)
    }

    @ViewBuilder
    private func rack(_ machines: [VBVirtualMachine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: Self.unitSpacing) {
                    RackController(
                        machines: machines,
                        monitor: library.activityMonitor,
                        showStorage: { StorageWindow.open(library: library) },
                        addMachine: { sessionManager.launchInstallWizard(library: library) }
                    )

                    ForEach(machines) { vm in
                        Button {
                            sessionManager.launchAndStart(vm, library: library)
                        } label: {
                            LibraryItemView(activity: library.activityMonitor.activity(for: vm.id), vm: vm, name: vm.name)
                        }
                        .buttonStyle(.vbLibraryItem)
                        .environmentObject(library)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(vm.id)
                    }

                    RackBlankingPlate {
                        sessionManager.launchInstallWizard(library: library)
                    }
                }
                .padding(Self.rackPadding)
            }
            /// Running virtual machines show what they're using and what's on their display while the library is on screen.
            /// Once it isn't, such as when a virtual machine's window covers it, measuring them and moving the lights would be
            /// work for nobody.
            .onWindowVisibilityChange { isLibraryVisible = $0 }
            .environment(\.rackIsAnimated, isLibraryVisible)
            .task(id: isLibraryVisible) {
                guard isLibraryVisible else { return }
                await library.activityMonitor.observe()
            }
            .task(id: isLibraryVisible) {
                guard isLibraryVisible else { return }

                while !Task.isCancelled {
                    await sessionManager.refreshPreviews()
                    try? await Task.sleep(for: VMLivePreview.refreshInterval)
                }
            }
            /// Brings a virtual machine that was just duplicated into view.
            .onChange(of: library.recentlyDuplicatedMachineIdentifier) { _, identifier in
                guard let identifier else { return }
                withAnimation { proxy.scrollTo(identifier, anchor: .center) }
            }
        }
        .environment(\.virtualBuddyShowDesktopPictureThumbnails, settingsContainer.settings.showDesktopPictureThumbnails)
    }

    @ViewBuilder
    private var libraryVolumeNotMountedMessage: some View {
        BackportedContentUnavailableView(
            "Library Not Mounted",
            systemImage: "externaldrive.badge.questionmark",
            description: Text("""
            The volume containing your Hypervisaur library is not currently mounted.
            Once mounted, your virtual machines will appear here.
            """)
        ) {
            Button("Try Again") {
                library.loadMachines()
            }
            .keyboardShortcut(.defaultAction)

            Button("Open Settings") {
                openSettings()
            }
        }
    }

    @ViewBuilder
    private var libraryDirectoryMissingMessage: some View {
        BackportedContentUnavailableView(
            "Library Missing",
            systemImage: "questionmark.folder",
            description: Text("""
            Hypervisaur is unable to locate your library directory.

            Review your settings to ensure the directory is set correctly. If it exists, there may be a permission problem.

            If you’ve deleted the library directory, you can start a new empty library.
            """)
        ) {
            Button("Open Settings") {
                openSettings()
            }
            .keyboardShortcut(.defaultAction)

            Button("Create Empty Library") {
                library.loadMachines(createLibrary: true)
            }
        }
    }

    @ViewBuilder
    private var libraryEmptyMessage: some View {
        BackportedContentUnavailableView(
            "No Virtual Machines",
            systemImage: "square.grid.2x2",
            description: Text("""
            You haven’t created any virtual machines yet. You can create a new one, or select a different library directory in settings.
            """)
        ) {
            Button("Create Virtual Machine") {
                sessionManager.launchInstallWizard(library: library)
            }
            .keyboardShortcut(.defaultAction)

            Button("Open Settings") {
                openSettings()
            }
        }
    }
}

fileprivate extension URL {
    var collapsedHomePath: String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

#if DEBUG
#Preview {
    LibraryView()
        .environmentObject(VMLibraryController.preview)
        .environmentObject(VirtualMachineSessionUIManager.shared)
}
#endif
