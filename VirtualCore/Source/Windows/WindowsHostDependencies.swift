import Foundation
import Combine
import OSLog

/// Software that must be installed on the host before Windows virtual machines can run.
public enum WindowsHostDependency: String, CaseIterable, Identifiable, Sendable {
    case homebrew
    case qemu
    case swtpm
    case wimlib
    case windowsDrivers

    public var id: RawValue { rawValue }

    public var name: String {
        switch self {
        case .homebrew: "Homebrew"
        case .qemu: "QEMU"
        case .swtpm: "swtpm"
        case .wimlib: "wimlib"
        case .windowsDrivers: "Windows Drivers"
        }
    }

    public var summary: String {
        switch self {
        case .homebrew: "Package manager used to install the other components."
        case .qemu: "Runs Windows using the Hypervisor framework, with UEFI firmware for ARM."
        case .swtpm: "Software TPM 2.0, required by Windows 11."
        case .wimlib: "Prepares the Windows installer so the virtual machine can read it quickly."
        case .windowsDrivers: "Network and other virtio drivers for Windows, signed by Microsoft. Downloaded from UTM’s guest tools on GitHub."
        }
    }

    public var systemImage: String {
        switch self {
        case .homebrew: "shippingbox"
        case .qemu: "cpu"
        case .swtpm: "lock.shield"
        case .wimlib: "doc.zipper"
        case .windowsDrivers: "network"
        }
    }

    /// The Homebrew formula that provides this dependency, `nil` for Homebrew itself and for things that aren't in Homebrew.
    public var formula: String? {
        switch self {
        case .homebrew, .windowsDrivers: nil
        case .qemu: "qemu"
        case .swtpm: "swtpm"
        case .wimlib: "wimlib"
        }
    }
}

@MainActor
public final class WindowsHostDependencies: ObservableObject {
    public enum Status: Hashable, Sendable {
        case unknown
        case installed(version: String?)
        case missing
        /// With a description of the progress, such as how much has been downloaded.
        case installing(String?)
        case failed(String)

        public var isInstalled: Bool {
            guard case .installed = self else { return false }
            return true
        }

        /// Whether installing the missing components would install this.
        var needsInstallation: Bool {
            switch self {
            case .missing, .failed: true
            case .unknown, .installed, .installing: false
            }
        }
    }

    public static let shared = WindowsHostDependencies()

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "WindowsHostDependencies")

    @Published public private(set) var statuses: [WindowsHostDependency: Status] = [:]
    @Published public private(set) var installationLog: [String] = []
    @Published public private(set) var isInstalling = false

    public var allInstalled: Bool {
        WindowsHostDependency.allCases.allSatisfy { status(for: $0).isInstalled }
    }

    /// Whether anything that's missing can be installed by the app, which needs Homebrew for everything but the drivers.
    public var canInstallMissing: Bool {
        guard !isInstalling else { return false }
        return status(for: .windowsDrivers).needsInstallation || (status(for: .homebrew).isInstalled && !formulaeToInstall.isEmpty)
    }

    private var formulaeToInstall: [String] {
        WindowsHostDependency.allCases.compactMap { dependency in
            guard let formula = dependency.formula, status(for: dependency).needsInstallation else { return nil }
            return formula
        }
    }

    public func status(for dependency: WindowsHostDependency) -> Status {
        statuses[dependency] ?? .unknown
    }

    /// Updates what's installed. Whether each component is installed is determined from its files, so it's immediate,
    /// and the versions of the Homebrew formulae are filled in afterwards.
    public func refresh() async {
        guard !isInstalling else { return }

        var updated = [WindowsHostDependency: Status]()
        updated[.windowsDrivers] = WindowsDrivers.isInstalled ? .installed(version: WindowsDrivers.version) : .missing

        let brew = Homebrew.current
        updated[.homebrew] = brew == nil ? .missing : .installed(version: nil)

        for dependency in WindowsHostDependency.allCases where dependency.formula != nil {
            if let brew, Self.requiredFilesExist(for: dependency, in: brew) {
                updated[dependency] = .installed(version: nil)
            } else {
                updated[dependency] = .missing
            }
        }

        /// Failures stay visible until the component has been installed some other way.
        for (dependency, status) in statuses {
            if case .failed = status, !(updated[dependency]?.isInstalled ?? false) {
                updated[dependency] = status
            }
        }

        statuses = updated

        guard let brew else { return }

        let formulae = WindowsHostDependency.allCases.compactMap(\.formula)
        let versions = await brew.installedVersions(of: formulae)

        guard !isInstalling else { return }

        for dependency in WindowsHostDependency.allCases {
            guard let formula = dependency.formula, statuses[dependency]?.isInstalled == true, let version = versions[formula] else { continue }
            statuses[dependency] = .installed(version: version)
        }
    }

    /// Installs the missing Homebrew formulae and downloads the drivers if they're missing. Only one installation runs at a time.
    public func installMissing() async {
        guard canInstallMissing else { return }

        isInstalling = true
        installationLog = []

        let appendToLog: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                self?.installationLog.append(line)
            }
        }

        let formulae = formulaeToInstall
        let needsDrivers = status(for: .windowsDrivers).needsInstallation

        if let brew = Homebrew.current, !formulae.isEmpty {
            setStatus(.installing("Installing with Homebrew"), forFormulae: formulae)

            do {
                try await brew.install(formulae, onOutput: appendToLog)
                setStatus(.installed(version: nil), forFormulae: formulae)
            } catch {
                logger.error("Homebrew installation failed: \(error, privacy: .public)")
                setStatus(.failed(error.localizedDescription), forFormulae: formulae)
            }
        }

        if needsDrivers {
            statuses[.windowsDrivers] = .installing("Downloading")

            do {
                try await WindowsDrivers.install(onOutput: appendToLog) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .installing = self.statuses[.windowsDrivers] else { return }
                        self.statuses[.windowsDrivers] = .installing("Downloading \(Int(fraction * 100))%")
                    }
                }
                statuses[.windowsDrivers] = .installed(version: WindowsDrivers.version)
            } catch {
                logger.error("Driver installation failed: \(error, privacy: .public)")
                appendToLog(error.localizedDescription)
                statuses[.windowsDrivers] = .failed(error.localizedDescription)
            }
        }

        isInstalling = false

        await refresh()
    }

    private func setStatus(_ status: Status, forFormulae formulae: [String]) {
        for dependency in WindowsHostDependency.allCases where formulae.contains(dependency.formula ?? "") {
            statuses[dependency] = status
        }
    }

    private static func requiredFilesExist(for dependency: WindowsHostDependency, in brew: Homebrew) -> Bool {
        let toolchain = QEMUToolchain(homebrew: brew)

        switch dependency {
        case .homebrew:
            return true
        case .qemu:
            return [toolchain.qemuURL, toolchain.firmwareCodeURL, toolchain.firmwareVariablesTemplateURL]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        case .swtpm:
            return FileManager.default.isExecutableFile(atPath: toolchain.swtpmURL.path)
        case .wimlib:
            return FileManager.default.isExecutableFile(atPath: toolchain.wimlibURL.path)
        case .windowsDrivers:
            return WindowsDrivers.isInstalled
        }
    }
}

/// Paths to the tools and firmware that are used to run Windows virtual machines.
public struct QEMUToolchain: Sendable {
    public let qemuURL: URL
    public let swtpmURL: URL
    public let wimlibURL: URL
    public let firmwareCodeURL: URL
    public let firmwareVariablesTemplateURL: URL

    public init(homebrew: Homebrew) {
        qemuURL = homebrew.binaryURL(named: "qemu-system-aarch64")
        swtpmURL = homebrew.binaryURL(named: "swtpm")
        wimlibURL = homebrew.binaryURL(named: "wimlib-imagex")
        firmwareCodeURL = homebrew.sharedResourceURL("qemu/edk2-aarch64-code.fd")
        firmwareVariablesTemplateURL = homebrew.sharedResourceURL("qemu/edk2-arm-vars.fd")
    }

    /// The toolchain installed on this Mac. Throws if something that's needed is missing.
    public static func current() throws -> QEMUToolchain {
        guard let brew = Homebrew.current else {
            throw Failure("Homebrew is not installed. Windows virtual machines need QEMU and swtpm from Homebrew.")
        }

        let toolchain = QEMUToolchain(homebrew: brew)

        let required: [(URL, String)] = [
            (toolchain.qemuURL, "qemu"),
            (toolchain.firmwareCodeURL, "qemu"),
            (toolchain.firmwareVariablesTemplateURL, "qemu"),
            (toolchain.swtpmURL, "swtpm"),
            (toolchain.wimlibURL, "wimlib"),
        ]

        if let missing = required.first(where: { !FileManager.default.fileExists(atPath: $0.0.path) }) {
            throw Failure("\(missing.0.lastPathComponent) is missing. Install it with “brew install \(missing.1)”.")
        }

        return toolchain
    }
}
