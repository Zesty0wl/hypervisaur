import SwiftUI
import VirtualCore

/// Toolbar buttons that take screenshots and recordings of the virtual machine's display.
struct VirtualMachineCaptureControls: View {
    @EnvironmentObject private var ui: VirtualMachineSessionUI

    var body: some View {
        Group {
            Button {
                Task { await ui.takeScreenshot() }
            } label: {
                Label("Take Screenshot", systemImage: "camera")
                    .labelStyle(.iconOnly)
            }
            .disabled(ui.isTakingScreenshot)
            .help("Save a screenshot of the virtual machine’s display")

            Button {
                Task { await ui.toggleRecording() }
            } label: {
                if let recording = ui.recording {
                    Label {
                        Text("Stop Recording")
                    } icon: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(.red)
                            Text(recording.startDate, style: .timer)
                                .monospacedDigit()
                        }
                    }
                    .labelStyle(.iconOnly)
                } else {
                    Label("Record", systemImage: "record.circle")
                        .labelStyle(.iconOnly)
                }
            }
            .help(ui.recording == nil ? "Record the virtual machine’s display and sound" : "Stop recording and save the movie")
        }
    }
}

/// Toolbar buttons that open a shell in the guest and show its logs, through the Hypervisaur agent in the guest.
struct VirtualMachineGuestAgentControls: View {
    @EnvironmentObject private var ui: VirtualMachineSessionUI

    var body: some View {
        Group {
            Button {
                ui.openShell()
            } label: {
                Label("Open Shell", systemImage: "terminal")
                    .labelStyle(.iconOnly)
            }
            .help("Open a shell in the virtual machine in Terminal")

            Button {
                ui.showLogs()
            } label: {
                Label("Show Logs", systemImage: "list.bullet.rectangle")
                    .labelStyle(.iconOnly)
            }
            .help("Show the virtual machine’s logs as they’re logged")
        }
    }
}

/// Tells the session which view the virtual machine's display fills. It's placed behind that view, so it has the same frame.
struct VMDisplayViewReader: NSViewRepresentable {
    var session: VirtualMachineSessionUI

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        session.displayView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.displayView = nsView
    }
}

/// Briefly says where a screenshot or recording was saved, with a button to show it in Finder.
struct VMCapturedFileBanner: View {
    var url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: url.pathExtension == "mov" ? "film" : "photo")
                .foregroundStyle(.secondary)

            Text("Saved “\(url.lastPathComponent)”")
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 2)
        .padding(.bottom, 16)
    }
}
