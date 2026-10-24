//
//  SoftwareUpdateController.swift
//  VirtualBuddy
//
//  Created by Guilherme Rambo on 25/06/22.
//

import SwiftUI
import VirtualCore
import BuddyFoundation
import OSLog

/// Tells people when a newer release of Hypervisaur is on GitHub, and takes them to it to download.
@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject {

    private let logger = Logger(subsystem: kShellAppSubsystem, category: "SoftwareUpdateController")

    static let shared = SoftwareUpdateController()

    private static let checkInterval = Duration.seconds(24 * 60 * 60)

    /// Gives the app a moment to finish launching before the first check.
    private static let launchDelay = Duration.seconds(10)

    private enum Keys {
        static let automaticallyChecks = "automaticallyChecksForUpdates"
        static let lastCheckDate = "lastUpdateCheckDate"
        static let skippedVersion = "skippedUpdateVersion"
    }

    private let defaults = UserDefaults.standard

    @Published var automaticUpdatesEnabled: Bool {
        didSet {
            guard automaticUpdatesEnabled != oldValue else { return }
            defaults.set(automaticUpdatesEnabled, forKey: Keys.automaticallyChecks)
            scheduleAutomaticChecks()
        }
    }

    var automaticUpdatesBinding: Binding<Bool>? {
        Binding { [self] in
            automaticUpdatesEnabled
        } set: { [self] newValue in
            automaticUpdatesEnabled = newValue
        }
    }

    private var automaticCheckTask: Task<Void, Never>?
    private var isChecking = false

    override init() {
        defaults.register(defaults: [Keys.automaticallyChecks: true])
        automaticUpdatesEnabled = defaults.bool(forKey: Keys.automaticallyChecks)
        super.init()
    }

    func activate() {
        scheduleAutomaticChecks()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Task { await check(userInitiated: true) }
    }

    private func scheduleAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil

        guard automaticUpdatesEnabled else { return }

        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.delayUntilNextCheck else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.check(userInitiated: false)
            }
        }
    }

    /// Checks are a day apart, including across launches.
    private var delayUntilNextCheck: Duration {
        guard let lastCheck = defaults.object(forKey: Keys.lastCheckDate) as? Date else { return Self.launchDelay }
        let remaining = Self.checkInterval - .seconds(Date.now.timeIntervalSince(lastCheck))
        return max(remaining, Self.launchDelay)
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let currentVersion = Bundle.main.softwareVersion

        do {
            let release = try await AppRelease.latest()
            defaults.set(Date.now, forKey: Keys.lastCheckDate)

            logger.info("Newest release is \(release.version, privacy: .public), this is \(currentVersion, privacy: .public)")

            if release.version > currentVersion {
                guard userInitiated || defaults.string(forKey: Keys.skippedVersion) != release.version.description else { return }
                presentAvailable(release, currentVersion: currentVersion, canSkip: !userInitiated)
            } else if userInitiated {
                presentUpToDate(currentVersion: currentVersion)
            }
        } catch {
            logger.error("Update check failed: \(error, privacy: .public)")

            /// Automatic checks fail quietly, such as when the Mac is offline, and try again the next day.
            if userInitiated {
                presentFailure(error)
            }
        }
    }

    private func presentAvailable(_ release: AppRelease, currentVersion: SoftwareVersion, canSkip: Bool) {
        let alert = NSAlert()
        alert.messageText = "\(release.name) Is Available"
        alert.informativeText = "You have Hypervisaur \(currentVersion). To update, download the installer from GitHub and open it. Your virtual machines stay as they are."
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Not Now")
        if canSkip {
            alert.addButton(withTitle: "Skip This Version")
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        case .alertThirdButtonReturn:
            defaults.set(release.version.description, forKey: Keys.skippedVersion)
        default:
            break
        }
    }

    private func presentUpToDate(currentVersion: SoftwareVersion) {
        let alert = NSAlert()
        alert.messageText = "Hypervisaur Is Up to Date"
        alert.informativeText = "Hypervisaur \(currentVersion) is the newest version."
        alert.runModal()
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hypervisaur Couldn’t Check for Updates"
        alert.informativeText = "\(error.localizedDescription) You can see the newest release on GitHub."
        alert.addButton(withTitle: "View Releases")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AppRelease.releasesPageURL)
        }
    }

}
