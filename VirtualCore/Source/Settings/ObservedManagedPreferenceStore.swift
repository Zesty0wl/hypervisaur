import Foundation
import ManagedPreferencesKit

/// Reads managed preferences from the app's defaults, like `UserDefaultsManagedPreferenceStore`, and observes each one with
/// key-value observing.
///
/// `UserDefaultsManagedPreferenceStore` observes `UserDefaults.didChangeNotification`, which is only posted for changes made
/// in this process. Restrictions change in other processes, when an MDM profile is installed or removed or with `defaults`,
/// and key-value observing is told about those too, so they take effect in virtual machines that are already running.
struct ObservedManagedPreferenceStore: ManagedPreferenceStore {
    var defaults: UserDefaults = .standard

    func value(forKey key: String, domain: String) -> Any? {
        defaults.object(forKey: key)
    }

    func valueIsForced(forKey key: String, domain: String) -> Bool {
        defaults.objectIsForced(forKey: key)
    }

    func observeChanges(
        forKey key: String,
        domain: String,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> ManagedPreferenceObservation? {
        let observer = DefaultsKeyObserver(defaults: defaults, key: key, handler: handler)
        return ManagedPreferenceObservation { observer.invalidate() }
    }
}

/// Calls a handler on the main actor whenever a key's value in some defaults changes, in this process or another.
private final class DefaultsKeyObserver: NSObject, @unchecked Sendable {
    nonisolated(unsafe) private static var context = 0

    private let defaults: UserDefaults
    private let key: String
    private let handler: @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var isObserving = true

    init(defaults: UserDefaults, key: String, handler: @escaping @MainActor @Sendable () -> Void) {
        /// Key-value observing would treat a key with periods as a path through several values.
        precondition(!key.contains("."), "Managed preference keys are observed as key paths, so they can't contain periods.")

        self.defaults = defaults
        self.key = key
        self.handler = handler
        super.init()

        defaults.addObserver(self, forKeyPath: key, options: [], context: &Self.context)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &Self.context else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        /// Changes from other processes are reported on whichever thread learns about them.
        let handler = handler
        Task { @MainActor in handler() }
    }

    func invalidate() {
        lock.withLock {
            guard isObserving else { return }
            isObserving = false
            defaults.removeObserver(self, forKeyPath: key, context: &Self.context)
        }
    }

    deinit {
        invalidate()
    }
}
