import Foundation
import ManagedPreferencesKit
import Testing
@testable import VirtualCore

/// Restrictions are turned on by MDM or with `defaults`, from another process, and must reach virtual machines that are
/// already running.
@MainActor
struct ManagedPreferenceObservationTests {
    private let suiteName = "com.neiljohn.hypervisaur.tests.\(UUID().uuidString)"
    private let key = "DisableSharedFolders"

    @Test func changesMadeInAnotherProcessAreObservedUntilTheObservationIsCancelled() async throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ObservedManagedPreferenceStore(defaults: defaults)
        let changes = ChangeCounter()

        let observation = try #require(store.observeChanges(forKey: key, domain: suiteName) { changes.count += 1 })

        try runDefaults("write", suiteName, key, "-bool", "YES")
        try await waitUntil { changes.count > 0 }
        #expect(store.value(forKey: key, domain: suiteName) as? Bool == true)

        observation.cancel()
        let countWhenCancelled = changes.count
        try runDefaults("write", suiteName, key, "-bool", "NO")
        try await Task.sleep(for: .seconds(1))

        #expect(changes.count == countWhenCancelled)
    }

    // MARK: - Helpers

    @MainActor
    private final class ChangeCounter {
        var count = 0
    }

    private func runDefaults(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "defaults \(arguments.joined(separator: " ")) failed")
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for the change to be observed")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
