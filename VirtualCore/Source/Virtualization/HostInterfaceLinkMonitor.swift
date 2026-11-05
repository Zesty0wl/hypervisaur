import Foundation
import OSLog
import SystemConfiguration

/// Refers to a monitor without keeping it alive, so that a notification that arrives after it's gone does nothing.
private final class HostInterfaceLinkMonitorReference {
    weak var monitor: HostInterfaceLinkMonitor?

    init(_ monitor: HostInterfaceLinkMonitor) {
        self.monitor = monitor
    }
}

private func hostInterfaceLinkMonitorCallback(
    _ store: SCDynamicStore,
    changedKeys: CFArray,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }

    MainActor.assumeIsolated {
        let reference = Unmanaged<HostInterfaceLinkMonitorReference>.fromOpaque(info).takeUnretainedValue()
        let keys = (changedKeys as NSArray).compactMap { $0 as? String }
        reference.monitor?.dynamicStoreDidChange(keys)
    }
}

/// Watches the link state of the Mac's network interfaces that virtual machines are bridged to, and reports when one becomes
/// active, such as when a cable is plugged in again or an adapter is reconnected, so that the bridge can be set up again.
@MainActor
final class HostInterfaceLinkMonitor {
    private let logger: Logger
    private let onBecameActive: (String) -> Void
    private var store: SCDynamicStore?
    private let interfaceIdentifierByKey: [String: String]
    private var linkStates: [String: Bool]

    /// Returns `nil` if the interfaces can't be watched, which is logged.
    ///
    /// - Parameter onBecameActive: Called on the main queue with the identifier of an interface whose link was down and is now up.
    init?(interfaceIdentifiers: Set<String>, logger: Logger, onBecameActive: @escaping (String) -> Void) {
        self.logger = logger
        self.onBecameActive = onBecameActive

        var context = SCDynamicStoreContext(
            version: 0,
            info: nil,
            retain: { info in
                _ = Unmanaged<HostInterfaceLinkMonitorReference>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                Unmanaged<HostInterfaceLinkMonitorReference>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let identifierByKey = Dictionary(uniqueKeysWithValues: interfaceIdentifiers.map { (Self.linkStateKey(for: $0), $0) })
        interfaceIdentifierByKey = identifierByKey
        linkStates = [:]

        /// The store keeps the reference alive with the context's callbacks.
        let monitorReference = HostInterfaceLinkMonitorReference(self)
        context.info = Unmanaged.passUnretained(monitorReference).toOpaque()

        guard let store = SCDynamicStoreCreate(
            nil,
            "Hypervisaur.HostInterfaceLinkMonitor" as CFString,
            hostInterfaceLinkMonitorCallback,
            &context
        ) else {
            logger.error("Failed to create SystemConfiguration dynamic store for bridge monitoring: error=\(SCError())")
            return nil
        }

        guard SCDynamicStoreSetNotificationKeys(store, Array(identifierByKey.keys) as CFArray, nil) else {
            logger.error("Failed to register bridge link-state notifications: error=\(SCError())")
            return nil
        }

        linkStates = Dictionary(uniqueKeysWithValues: interfaceIdentifiers.map {
            ($0, Self.isLinkActive(interfaceIdentifier: $0, store: store))
        })

        guard SCDynamicStoreSetDispatchQueue(store, .main) else {
            logger.error("Failed to schedule bridge link-state notifications: error=\(SCError())")
            return nil
        }

        self.store = store

        let monitoredInterfaces = interfaceIdentifiers.sorted().joined(separator: ", ")
        logger.info("Monitoring host link state for bridged interface(s): \(monitoredInterfaces, privacy: .public)")
    }

    func stop() {
        guard let store else { return }

        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    fileprivate func dynamicStoreDidChange(_ changedKeys: [String]) {
        guard let store else { return }

        for key in Set(changedKeys) {
            guard let interfaceIdentifier = interfaceIdentifierByKey[key] else { continue }

            let wasActive = linkStates[interfaceIdentifier]
            let isActive = Self.isLinkActive(interfaceIdentifier: interfaceIdentifier, store: store)
            linkStates[interfaceIdentifier] = isActive

            logger.debug("Host bridge interface \(interfaceIdentifier, privacy: .public) link state changed: active=\(isActive)")

            guard wasActive == false, isActive else { continue }

            onBecameActive(interfaceIdentifier)
        }
    }

    private static func linkStateKey(for interfaceIdentifier: String) -> String {
        SCDynamicStoreKeyCreateNetworkInterfaceEntity(
            nil,
            kSCDynamicStoreDomainState,
            interfaceIdentifier as CFString,
            kSCEntNetLink
        ) as String
    }

    private static func isLinkActive(interfaceIdentifier: String, store: SCDynamicStore) -> Bool {
        let key = linkStateKey(for: interfaceIdentifier)

        guard let linkState = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
            return false
        }

        return linkState[kSCPropNetLinkActive as String] as? Bool == true
    }
}
