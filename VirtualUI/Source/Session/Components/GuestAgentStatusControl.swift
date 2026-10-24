import SwiftUI
import VirtualCore
import VirtualWormhole

/// Toolbar indicator for the Hypervisaur agent in a running Windows or Linux virtual machine, which shells, logs and copying
/// files need. macOS virtual machines show the guest app's status instead, since their agent is part of it.
struct GuestAgentStatusControl: View {
    var status: GuestAgentStatus
    var systemType: VBGuestType

    @State private var isShowingDetail = false

    var body: some View {
        Button {
            isShowingDetail.toggle()
        } label: {
            Label {
                Text(status.title)
            } icon: {
                /// The same symbol as the guest app's status, so that every guest shows Hypervisaur's helper the same way.
                Image(.guestSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .opacity(status.isConnected ? 1 : 0.6)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(status.indicatorColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: 2)
                    }
            }
            .labelStyle(.iconOnly)
        }
        .help(status.title)
        .popover(isPresented: $isShowingDetail, arrowEdge: .bottom) {
            GuestAgentStatusDetail(status: status, systemType: systemType)
        }
    }
}

private struct GuestAgentStatusDetail: View {
    var status: GuestAgentStatus
    var systemType: VBGuestType

    private static let linuxInstallCommand = "sudo mount -o ro /dev/disk/by-label/HYPERVISAUR /mnt && sudo sh /mnt/install.sh"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.indicatorColor)
                    .frame(width: 8, height: 8)

                Text(status.title)
                    .font(.headline)
            }

            if let info = status.info {
                Text(info.system)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(explanation)
                .foregroundStyle(.secondary)

            if systemType == .linux, status == .disconnected {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.linuxInstallCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.linuxInstallCommand, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading)
        .padding()
    }

    private var explanation: String {
        switch (status, systemType) {
        case (.connected, _):
            "Open Shell, Show Logs and copying files by dragging them work in this virtual machine."
        case (.outdated, .windows):
            "Open Shell and Show Logs work, but copying files needs a newer agent. Windows installs it from the DRIVERS drive when it restarts."
        case (.outdated, _):
            "Open Shell and Show Logs work. Hypervisaur is installing a newer agent, which copying files needs, and it reconnects in a moment."
        case (.disconnected, .windows):
            "Windows installs the agent from the DRIVERS drive when it starts. If it still isn’t connected once Windows has started, open the DRIVERS drive in Windows, then right-click VirtIODrivers\\Setup.cmd and choose Run as Administrator."
        case (.disconnected, _):
            "Open Shell, Show Logs and copying files need the agent. Install it from the HYPERVISAUR disc by running this in a terminal in Linux:"
        }
    }
}

private extension GuestAgentStatus {
    var info: GuestAgentInfo? {
        switch self {
        case .connected(let info), .outdated(let info): info
        case .disconnected: nil
        }
    }

    var isConnected: Bool { info != nil }

    var title: String {
        switch self {
        case .connected: "Hypervisaur Agent Is Connected"
        case .outdated: "Hypervisaur Agent Needs Updating"
        case .disconnected: "Hypervisaur Agent Is Not Connected"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .connected: .green
        case .outdated: .yellow
        case .disconnected: .orange
        }
    }
}
