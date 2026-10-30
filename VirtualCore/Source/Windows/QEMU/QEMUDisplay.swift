import Foundation
import CoreGraphics
import OSLog

/// A change to what the guest's display shows.
public enum QEMUDisplayChange: Sendable {
    /// The display shows a new surface, such as after the guest changed its resolution, or nothing once it's turned off.
    case surface(QEMUDisplaySurface?)
    /// An area of the surface changed, in its pixels.
    case update(CGRect)
    /// The guest asked for this pointer to be shown.
    case cursor(QEMUCursor)
    /// Whether the guest's pointer is shown.
    case cursorVisibility(Bool)
}

/// The guest's display, which QEMU serves with its D-Bus display.
///
/// QEMU is started with `-display dbus,p2p=yes`, and is given one end of a socket pair to serve the display on. A
/// listener is registered for the guest's first display, which QEMU tells about everything shown on it. When it can,
/// QEMU shares the memory it draws the display into, and only says which areas of it changed, so the pixels never have
/// to be copied. The framebuffer that Windows uses before its drivers are installed can't be shared, so QEMU sends its
/// pixels instead. See ``QEMUDisplayListener``.
///
/// Keyboard and mouse input and the clipboard still go through ``VNCClient``.
final class QEMUDisplay: @unchecked Sendable {
    static let consolePath = "/org/qemu/Display1/Console_0"
    static let consoleInterface = "org.qemu.Display1.Console"

    private let connection: DBusConnection
    private let listener: QEMUDisplayListener
    private var listenerConnection: DBusConnection?

    private let lock = NSLock()
    private var pendingChanges = [QEMUDisplayChange]()
    private var isDeliveryScheduled = false
    private var didDisconnect = false

    /// Called on the main queue with what changed on the display, in order. Changes that happen while the main queue is
    /// busy are passed on together, with the areas that changed combined.
    var onChange: (([QEMUDisplayChange]) -> Void)?

    /// Called on the main queue once when the display's connection ends.
    var onDisconnect: ((Error?) -> Void)?

    private init(connection: DBusConnection) {
        self.connection = connection
        self.listener = QEMUDisplayListener()
        listener.onChange = { [weak self] change in self?.enqueue(change) }
    }

    /// Connects to QEMU's D-Bus display through its monitor, and registers a listener for the guest's first display.
    static func connect(monitor: QMPClient) async throws -> QEMUDisplay {
        let (local, remote) = try OwnedFileDescriptor.socketPair()
        let descriptorName = "hypervisaur-display"

        try await monitor.execute("getfd", arguments: ["fdname": descriptorName], passing: remote)
        try await monitor.execute("add_client", arguments: ["protocol": "@dbus-display", "fdname": descriptorName])

        let connection = DBusConnection(socket: local, name: "Display")
        try await connection.authenticate()

        let display = QEMUDisplay(connection: connection)
        connection.start { [weak display] error in display?.connectionDidEnd(error) }

        do {
            try await display.registerListener()
        } catch {
            display.close()
            throw error
        }

        return display
    }

    private func registerListener() async throws {
        let (local, remote) = try OwnedFileDescriptor.socketPair()
        let listenerConnection = DBusConnection(socket: local, name: "Display listener")
        lock.withLock { self.listenerConnection = listenerConnection }

        let connection = connection

        /// QEMU authenticates the listener's connection before it replies, so that has to happen while the reply is awaited.
        async let registration = connection.call(
            path: Self.consolePath,
            interface: Self.consoleInterface,
            member: "RegisterListener",
            body: [.unixFD(0)],
            fileDescriptors: [remote]
        )

        do {
            try await listenerConnection.authenticate()
        } catch {
            /// Closing the connection fails the registration, which is waited for before giving up.
            connection.close()
            _ = try? await registration
            throw error
        }

        let listener = listener
        listenerConnection.start(handlingMethodCallsWith: { listener.handle($0) }) { [weak self] error in
            self?.connectionDidEnd(error)
        }

        _ = try await registration
    }

    func close() {
        connection.close()
        lock.withLock { listenerConnection }?.close()
    }

    private func connectionDidEnd(_ error: Error?) {
        let shouldReport: Bool = lock.withLock {
            guard !didDisconnect else { return false }
            didDisconnect = true
            return true
        }
        guard shouldReport else { return }

        close()

        DispatchQueue.main.async { [self] in
            onDisconnect?(error)
            onDisconnect = nil
        }
    }

    private func enqueue(_ change: QEMUDisplayChange) {
        let shouldSchedule: Bool = lock.withLock {
            switch change {
            case .surface:
                /// Whatever was shown before is replaced, so what changed on it no longer matters.
                pendingChanges.removeAll { pending in
                    switch pending {
                    case .surface, .update: true
                    case .cursor, .cursorVisibility: false
                    }
                }
                pendingChanges.append(change)
            case .update(let area):
                if case .update(let pendingArea) = pendingChanges.last {
                    pendingChanges[pendingChanges.count - 1] = .update(pendingArea.union(area))
                } else {
                    pendingChanges.append(change)
                }
            case .cursor, .cursorVisibility:
                pendingChanges.append(change)
            }

            guard !isDeliveryScheduled else { return false }
            isDeliveryScheduled = true
            return true
        }

        guard shouldSchedule else { return }

        DispatchQueue.main.async { [self] in
            let changes: [QEMUDisplayChange] = lock.withLock {
                isDeliveryScheduled = false
                defer { pendingChanges.removeAll() }
                return pendingChanges
            }
            onChange?(changes)
        }
    }
}

/// The listener that QEMU tells about what's shown on the guest's display, on the thread that the listener's connection
/// reads messages on.
final class QEMUDisplayListener: @unchecked Sendable {
    static let path = "/org/qemu/Display1/Listener"
    static let interface = "org.qemu.Display1.Listener"
    /// The listener can map the memory that QEMU draws the display into, which QEMU only shares if the listener says so.
    static let sharedMemoryInterface = "org.qemu.Display1.Listener.Unix.Map"

    private static let propertiesInterface = "org.freedesktop.DBus.Properties"

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "QEMUDisplayListener")

    /// What the display shows, which updates apply to.
    private(set) var surface: QEMUDisplaySurface?

    /// Called with each change to the display.
    var onChange: ((QEMUDisplayChange) -> Void)?

    func handle(_ call: DBusMessage) -> DBusConnection.MethodResult {
        if call.interface == "org.freedesktop.DBus.Peer", call.member == "Ping" {
            return .reply([])
        }

        guard call.path == Self.path else { return .unknownMethod(call) }

        do {
            switch (call.interface, call.member) {
            case (Self.propertiesInterface, "Get"):
                return try property(call.body)
            case (Self.propertiesInterface, "GetAll"):
                return try allProperties(call.body)
            case ("org.freedesktop.DBus.Introspectable", "Introspect"):
                return .reply([.string(Self.introspection)])
            case (Self.interface, "Scanout"):
                try scanout(call.body)
            case (Self.interface, "Update"):
                try update(call.body)
            case (Self.sharedMemoryInterface, "ScanoutMap"):
                try scanoutMap(call.body, fileDescriptors: call.fileDescriptors)
            case (Self.sharedMemoryInterface, "UpdateMap"):
                try updateMap(call.body)
            case (Self.interface, "Disable"):
                surface = nil
                onChange?(.surface(nil))
            case (Self.interface, "MouseSet"):
                try mouseSet(call.body)
            case (Self.interface, "CursorDefine"):
                try cursorDefine(call.body)
            default:
                return .unknownMethod(call)
            }
        } catch {
            logger.error("Couldn't handle \(call.member ?? "", privacy: .public): \(error, privacy: .public)")
            return .invalidArguments(error.localizedDescription)
        }

        return .reply([])
    }

    // MARK: - Properties

    private static var interfacesProperty: DBusValue { .strings([sharedMemoryInterface]) }

    private func property(_ arguments: [DBusValue]) throws -> DBusConnection.MethodResult {
        guard arguments.count == 2, let interface = arguments[0].stringValue, let name = arguments[1].stringValue else {
            throw Failure("Get takes an interface and a property’s name.")
        }
        guard interface == Self.interface, name == "Interfaces" else {
            return .invalidArguments("\(interface) has no property named \(name).")
        }
        return .reply([.variant(Self.interfacesProperty)])
    }

    private func allProperties(_ arguments: [DBusValue]) throws -> DBusConnection.MethodResult {
        guard arguments.count == 1, let interface = arguments[0].stringValue else {
            throw Failure("GetAll takes an interface.")
        }

        let properties: [DBusValue] = interface == Self.interface
            ? [.dictEntry(.string("Interfaces"), .variant(Self.interfacesProperty))]
            : []

        return .reply([.array(of: .dictEntry(key: .string, value: .variant), properties)])
    }

    // MARK: - Display

    private func scanout(_ arguments: [DBusValue]) throws {
        guard arguments.count == 5,
              let width = arguments[0].uint32Value, let height = arguments[1].uint32Value,
              let bytesPerRow = arguments[2].uint32Value, let format = arguments[3].uint32Value,
              let pixels = arguments[4].bytesValue
        else { throw Failure("Scanout’s arguments are wrong.") }

        let surface = try QEMUDisplaySurface(width: Int(width), height: Int(height), bytesPerRow: Int(width) * 4, pixmanFormat: format)
        surface.write(pixels, x: 0, y: 0, width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow))

        self.surface = surface
        onChange?(.surface(surface))
    }

    private func update(_ arguments: [DBusValue]) throws {
        guard arguments.count == 7,
              let x = arguments[0].int32Value, let y = arguments[1].int32Value,
              let width = arguments[2].int32Value, let height = arguments[3].int32Value,
              let bytesPerRow = arguments[4].uint32Value, let format = arguments[5].uint32Value,
              let pixels = arguments[6].bytesValue
        else { throw Failure("Update’s arguments are wrong.") }

        /// Updates only come after a scanout of the same format, and apply to it.
        guard let surface, !surface.isShared, surface.pixelFormat == QEMUDisplaySurface.PixelFormat(pixmanFormat: format) else { return }

        surface.write(pixels, x: Int(x), y: Int(y), width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow))
        reportUpdate(x: x, y: y, width: width, height: height)
    }

    private func scanoutMap(_ arguments: [DBusValue], fileDescriptors: [OwnedFileDescriptor]) throws {
        guard arguments.count == 6,
              let index = arguments[0].unixFDIndex, fileDescriptors.indices.contains(index),
              let offset = arguments[1].uint32Value,
              let width = arguments[2].uint32Value, let height = arguments[3].uint32Value,
              let bytesPerRow = arguments[4].uint32Value, let format = arguments[5].uint32Value
        else { throw Failure("ScanoutMap’s arguments are wrong.") }

        let surface = try QEMUDisplaySurface(
            sharedMemory: fileDescriptors[index],
            offset: Int(offset),
            width: Int(width),
            height: Int(height),
            bytesPerRow: Int(bytesPerRow),
            pixmanFormat: format
        )

        self.surface = surface
        onChange?(.surface(surface))
    }

    private func updateMap(_ arguments: [DBusValue]) throws {
        guard arguments.count == 4,
              let x = arguments[0].int32Value, let y = arguments[1].int32Value,
              let width = arguments[2].int32Value, let height = arguments[3].int32Value
        else { throw Failure("UpdateMap’s arguments are wrong.") }

        guard surface?.isShared == true else { return }

        reportUpdate(x: x, y: y, width: width, height: height)
    }

    private func reportUpdate(x: Int32, y: Int32, width: Int32, height: Int32) {
        guard let surface else { return }

        let area = CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)).intersection(surface.bounds)
        guard !area.isNull, !area.isEmpty else { return }

        onChange?(.update(area))
    }

    // MARK: - Pointer

    private func mouseSet(_ arguments: [DBusValue]) throws {
        guard arguments.count == 3, let isShown = arguments[2].int32Value else { throw Failure("MouseSet’s arguments are wrong.") }

        onChange?(.cursorVisibility(isShown != 0))
    }

    private func cursorDefine(_ arguments: [DBusValue]) throws {
        guard arguments.count == 5,
              let width = arguments[0].int32Value, let height = arguments[1].int32Value,
              let hotSpotX = arguments[2].int32Value, let hotSpotY = arguments[3].int32Value,
              let pixels = arguments[4].bytesValue
        else { throw Failure("CursorDefine’s arguments are wrong.") }

        onChange?(.cursor(try QEMUCursor(width: Int(width), height: Int(height), hotSpotX: Int(hotSpotX), hotSpotY: Int(hotSpotY), pixels: pixels)))
    }

    private static let introspection = """
    <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    <node>
      <interface name="org.qemu.Display1.Listener">
        <method name="Scanout"><arg type="u" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/><arg type="ay" direction="in"/></method>
        <method name="Update"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/><arg type="ay" direction="in"/></method>
        <method name="Disable"/>
        <method name="MouseSet"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
        <method name="CursorDefine"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="ay" direction="in"/></method>
        <property name="Interfaces" type="as" access="read"/>
      </interface>
      <interface name="org.qemu.Display1.Listener.Unix.Map">
        <method name="ScanoutMap"><arg type="h" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/><arg type="u" direction="in"/></method>
        <method name="UpdateMap"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      </interface>
    </node>
    """
}
