import Foundation
import Combine
import IOKit.pwr_mgt
import VirtualWormhole
import OSLog

/// Keeps a virtual machine from going to sleep while it runs in the background, the equivalent of `caffeinate -disu`.
///
/// The Mac is kept from going to sleep when it's idle, which would put the virtual machine to sleep with it, although its
/// display can still turn off. In the guest, the Hypervisaur agent runs a program that keeps it awake until it's stopped:
/// `caffeinate` in macOS, `systemd-inhibit` in Linux, and `SetThreadExecutionState` in Windows. A guest whose agent
/// isn't running yet is kept awake once it starts, and again after it restarts, such as when the guest restarts.
@MainActor
public final class VMSleepPrevention {
    /// What runs in the guest to keep it awake, with the guest's shell. Agents stop the whole program when it's terminated.
    static func guestCommand(for systemType: VBGuestType) -> String {
        switch systemType {
        case .mac:
            "exec /usr/bin/caffeinate -disu"
        case .linux:
            "exec systemd-inhibit --what=idle:sleep --who=Hypervisaur --why='Running in the background' --mode=block sleep infinity"
        case .windows:
            /// `ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED`, which lasts for as long as the thread that set it.
            """
            $ErrorActionPreference = 'Stop'; \
            $power = Add-Type -Name Power -Namespace Hypervisaur -PassThru -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'; \
            [void]$power::SetThreadExecutionState([uint32]2147483651); \
            while ($true) { Start-Sleep -Seconds 3600 }
            """
        }
    }

    /// A program that ends sooner than this after starting most likely can't keep the guest awake at all.
    private static let minimumGuestProgramLifetime: TimeInterval = 30
    /// How many programs in a row may end too soon before trying again is pointless.
    private static let maximumGuestProgramFailures = 3
    /// How long to wait before starting the program again after it ended.
    private static let guestProgramRetryDelay = Duration.seconds(10)

    private let controller: VMController
    private let logger: Logger

    public private(set) var isActive = false

    private var hostAssertion: HostSleepAssertion?
    private var agentObservation: AnyCancellable?
    private var retryTask: Task<Void, Never>?

    /// Identifies the program that's running now, so that events about one that has been replaced are ignored.
    private var guestProgramToken: UUID?
    private var guestProgram: GuestAgentConnection.Channel?
    private var guestProgramStartDate: Date?
    private var guestProgramFailures = 0

    public init(controller: VMController) {
        self.controller = controller
        self.logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "SleepPrevention(\(controller.virtualMachineModel.name))")
    }

    public func start() {
        guard !isActive else { return }

        isActive = true
        guestProgramFailures = 0

        hostAssertion = HostSleepAssertion(reason: "“\(controller.virtualMachineModel.name)” is running in the background", logger: logger)

        /// The agent connects some time after the guest starts, and again after it restarts.
        agentObservation = controller.$guestAgentInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                MainActor.assumeIsolated {
                    guard info != nil else { return }
                    self?.startGuestProgramIfNeeded()
                }
            }

        logger.info("Keeping the virtual machine awake")
    }

    public func stop() {
        guard isActive else { return }

        isActive = false
        agentObservation = nil
        retryTask?.cancel()
        retryTask = nil
        hostAssertion = nil

        guestProgram?.terminate()
        guestProgram = nil
        guestProgramToken = nil

        logger.info("No longer keeping the virtual machine awake")
    }

    private func startGuestProgramIfNeeded() {
        guard isActive, guestProgram == nil, guestProgramFailures < Self.maximumGuestProgramFailures else { return }

        /// Without an agent, the program starts once the agent connects.
        guard let agent = controller.guestAgent, agent.info != nil else { return }

        let token = UUID()
        let command = Self.guestCommand(for: controller.virtualMachineModel.configuration.systemType)

        do {
            guestProgram = try agent.open(GuestAgentOpenRequest(command: command)) { [weak self] event in
                switch event {
                case .output:
                    break
                case .errorOutput(let data):
                    let message = String(decoding: data, as: UTF8.self)
                    Task { @MainActor [weak self] in
                        self?.logger.warning("The guest's sleep prevention reported: \(message, privacy: .public)")
                    }
                case .exited(let status):
                    Task { @MainActor [weak self] in
                        self?.guestProgramEnded(token: token, reason: "exited with status \(status)", countsAsFailure: true)
                    }
                case .failed(let message):
                    Task { @MainActor [weak self] in
                        self?.guestProgramEnded(token: token, reason: message, countsAsFailure: false)
                    }
                }
            }
            guestProgramToken = token
            guestProgramStartDate = .now
        } catch {
            logger.notice("Couldn't keep the guest awake yet: \(error, privacy: .public)")
        }
    }

    /// - Parameter countsAsFailure: `false` when the program ended because the connection to the agent did, such as when
    /// the guest restarts, which says nothing about whether it works.
    private func guestProgramEnded(token: UUID, reason: String, countsAsFailure: Bool) {
        guard token == guestProgramToken else { return }

        guestProgram = nil
        guestProgramToken = nil

        guard isActive else { return }

        let lifetime = guestProgramStartDate.map { Date.now.timeIntervalSince($0) } ?? 0

        if countsAsFailure, lifetime < Self.minimumGuestProgramLifetime {
            guestProgramFailures += 1
        } else {
            guestProgramFailures = 0
        }

        guard guestProgramFailures < Self.maximumGuestProgramFailures else {
            logger.error("The guest can't be kept awake, its program \(reason, privacy: .public) every time it started")
            return
        }

        logger.notice("The guest's sleep prevention \(reason, privacy: .public), starting it again")

        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.guestProgramRetryDelay)
            guard !Task.isCancelled else { return }
            self?.startGuestProgramIfNeeded()
        }
    }
}

/// Keeps the Mac from going to sleep when it's idle for as long as it exists.
private final class HostSleepAssertion {
    private let id: IOPMAssertionID

    init?(reason: String, logger: Logger) {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )

        guard result == kIOReturnSuccess else {
            logger.error("Couldn't keep the Mac awake: IOPMAssertionCreateWithName returned \(result)")
            return nil
        }

        self.id = id
    }

    deinit {
        IOPMAssertionRelease(id)
    }
}
