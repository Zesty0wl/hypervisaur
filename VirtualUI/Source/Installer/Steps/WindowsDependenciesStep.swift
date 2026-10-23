import SwiftUI
import VirtualCore

struct WindowsDependenciesStep: View {
    @ObservedObject private var dependencies = WindowsHostDependencies.shared

    @Environment(\.maxContentWidth)
    private var maxContentWidth

    private var homebrewMissing: Bool {
        dependencies.status(for: .homebrew) == .missing
    }

    private var canInstall: Bool { dependencies.canInstallMissing }

    private var hasFailures: Bool {
        WindowsHostDependency.allCases.contains {
            if case .failed = dependencies.status(for: $0) { true } else { false }
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 20) {
                header

                dependencyList

                if homebrewMissing {
                    HomebrewInstallInstructions {
                        Task { await dependencies.refresh() }
                    }
                }

                if dependencies.isInstalling {
                    Label("Installing. This can take a few minutes.", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                } else if canInstall {
                    Button {
                        Task { await dependencies.installMissing() }
                    } label: {
                        Label(hasFailures ? "Try Again" : (homebrewMissing ? "Download Drivers" : "Install Missing Components"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if (dependencies.isInstalling || hasFailures) && !dependencies.installationLog.isEmpty {
                    InstallationOutputView(lines: dependencies.installationLog)
                }

                Text("You’ll also need a Windows 11 disc image (ISO) for ARM64, which you can download from Microsoft. You’ll choose it next.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: maxContentWidth ?? 600)
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await dependencies.refresh() }
        /// Picks up what was installed from Terminal, such as Homebrew itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await dependencies.refresh() }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 12) {
            VBGuestType.windows.icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 56)

            Text("Windows Requirements")
                .font(.system(.title, design: .rounded).weight(.medium))

            Text("Windows runs using QEMU and the Hypervisor framework, with a software TPM for Windows 11, and wimlib prepares the Windows installer. VirtualBuddy installs these with Homebrew, and downloads the drivers Windows needs for its network adapter.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
        .shadow(color: .black.opacity(0.3), radius: 1, x: 0.5, y: 0.5)
    }

    @ViewBuilder
    private var dependencyList: some View {
        VStack(spacing: 0) {
            ForEach(WindowsHostDependency.allCases) { dependency in
                WindowsDependencyRow(dependency: dependency, status: dependencies.status(for: dependency))

                if dependency != WindowsHostDependency.allCases.last {
                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
        .padding(.vertical, 4)
        .controlGroup()
    }
}

private struct WindowsDependencyRow: View {
    var dependency: WindowsHostDependency
    var status: WindowsHostDependencies.Status

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: dependency.systemImage)
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(dependency.name)
                    .font(.headline)

                Text(dependency.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .failed(let message) = status {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            statusView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .installing(let description):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(description ?? "Installing")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .installed(let version):
            Label(version ?? "Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .monospacedDigit()
        case .missing:
            Label("Not Installed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

private struct HomebrewInstallInstructions: View {
    var checkAgain: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Homebrew")
                .font(.headline)

            Text("Homebrew needs an administrator password, so it’s installed from Terminal. Paste this command in Terminal, then come back and check again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(Homebrew.installCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Button(copied ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Homebrew.installCommand, forType: .string)
                    copied = true
                }

                Button("Open Terminal") {
                    if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                        NSWorkspace.shared.openApplication(at: terminalURL, configuration: .init())
                    }
                }

                Link("brew.sh", destination: Homebrew.websiteURL)

                Spacer()

                Button("Check Again", action: checkAgain)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding()
        .controlGroup(level: .secondary)
    }
}

private struct InstallationOutputView: View {
    var lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
            }
            .frame(height: 160)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: lines.count) {
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }
}

#if DEBUG
#Preview {
    VMInstallationWizard.preview(step: .dependencies)
}
#endif
