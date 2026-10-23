import SwiftUI
import Observation
import OSLog
import VirtualCore

@Observable
@MainActor
public final class VBUSBDeviceRepository {
    private let logger = Logger(for: VBUSBDeviceRepository.self)

    public static let shared = VBUSBDeviceRepository()

    private let store = USBNameDatabase.Store(
        remoteURL: URL(string: "https://raw.githubusercontent.com/usbids/usbids/master/usb.ids")!,
        cacheURL: URL.defaultVirtualBuddyLibraryURL.appending(path: "usb.ids")
    )

    private var database: USBNameDatabase

    private init() {
        database = store.cached() ?? .empty
    }

    private var updateTask: Task<Void, Never>?

    public func updateIfNeeded() {
        guard updateTask == nil, store.needsRefresh else { return }

        updateTask = Task {
            defer { updateTask = nil }

            do {
                self.database = try await store.refreshed()
            } catch {
                logger.warning("Database update failed: \(error, privacy: .public)")
            }
        }
    }

    public func device(vendorID: UInt16, productID: UInt16) -> VBUSBDevice {
        VBUSBDevice(
            vendorID: vendorID,
            productID: productID,
            name: database.displayName(vendorID: vendorID, productID: productID) ?? "USB Device"
        )
    }
}
