//
//  GeneralSettingsView.swift
//  VirtualBuddy
//
//  Created by Guilherme Rambo on 20/06/25.
//

import SwiftUI
import VirtualCore
import BuddyUI

struct GeneralSettingsView: View {
    @Binding var settings: VBSettings
    /// `nil` when the app can't update itself, which hides the update settings.
    var enableAutomaticUpdates: Binding<Bool>?
    @Binding var alert: AlertContent

    @State private var libraryPathText = ""

    private var libraryPath: String { settings.libraryURL.absoluteURL.path(percentEncoded: false) }

    var body: some View {
        Form {
            Section {
                FileSystemPathFormControl(url: settings.libraryURL, contentTypes: [.folder], defaultDirectoryKey: "library") { newURL in
                    setLibraryPath(to: newURL.path)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Hypervisaur saves your virtual machines and downloaded installer images here.")
                    .settingsFooterStyle()
            }

            Section {
                Picker("When closing a running virtual machine", selection: $settings.closeBehavior) {
                    ForEach(VMCloseBehavior.allCases) { behavior in
                        Text(behavior.title)
                            .tag(behavior)
                    }
                }

                Toggle("Prevent sleep while running in background", isOn: $settings.keepsBackgroundVirtualMachinesAwake)
            } header: {
                Text("Closing Virtual Machines")
            } footer: {
                Text("Save state keeps the virtual machine as it is so that it continues where you left off. This feature is available for macOS and Windows guests. Keep running in background closes the window and leaves the virtual machine running until it shuts down; open it from the library to show its window again. Preventing sleep keeps virtual machines in the background and this Mac awake, although the Mac’s display can still turn off.")
                    .settingsFooterStyle()
            }

            if let enableAutomaticUpdates {
                Section {
                    Toggle("Automatically check for updates", isOn: enableAutomaticUpdates)
                } header: {
                    Text("App Updates")
                } footer: {
                    Text("Hypervisaur checks GitHub for a new release once a day, and tells you when there is one.")
                        .settingsFooterStyle()
                }
            }
        }
        .navigationTitle(Text("General"))
        .task(id: settings.libraryURL.path) {
            libraryPathText = settings.libraryURL.path
        }
    }

    private func setLibraryPath(to newValue: String) {
        let url = URL(fileURLWithPath: newValue)

        if let errorMessage = url.performWriteTest() {
            libraryPathText = settings.libraryURL.path

            alert = AlertContent(errorMessage)
        } else {
            settings.libraryURL = url
            libraryPathText = url.path

            alert = .init()
        }
    }
}

extension URL {
    func performWriteTest() -> String? {
        if !FileManager.default.fileExists(atPath: path) {
            return "The directory \(lastPathComponent) doesn't exist."
        }

        do {
            let testFileURL = appendingPathComponent(".vbtest-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: testFileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: testFileURL)
            return nil
        } catch {
            return "Hypervisaur is unable to write files to the directory \(lastPathComponent). Please check the permissions for that directory or choose a different one."
        }
    }
}

struct LibraryPathError: LocalizedError {
    var errorDescription: String?

    init(_ msg: String) { self.errorDescription = msg }
}

#if DEBUG
#Preview("Library Settings") {
    SettingsScreen.preview(.general)
}
#endif
