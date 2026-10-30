import Foundation
import CoreGraphics
import Testing
@testable import VirtualCore

struct QEMUDisplayListenerTests {
    private static let bgrx: UInt32 = 0x2002_0888

    @Test func saysItCanMapSharedMemory() throws {
        let listener = QEMUDisplayListener()

        let all = listener.handle(Self.call("GetAll", interface: "org.freedesktop.DBus.Properties", body: [.string(QEMUDisplayListener.interface)]))
        guard case .reply(let allBody) = all else { Issue.record("GetAll failed: \(all)"); return }
        #expect(allBody == [
            .array(of: .dictEntry(key: .string, value: .variant), [
                .dictEntry(.string("Interfaces"), .variant(.strings([QEMUDisplayListener.sharedMemoryInterface]))),
            ]),
        ])

        let one = listener.handle(Self.call("Get", interface: "org.freedesktop.DBus.Properties", body: [.string(QEMUDisplayListener.interface), .string("Interfaces")]))
        guard case .reply(let oneBody) = one else { Issue.record("Get failed: \(one)"); return }
        #expect(oneBody == [.variant(.strings([QEMUDisplayListener.sharedMemoryInterface]))])
    }

    @Test func showsTheMemoryThatQEMUShares() throws {
        let listener = QEMUDisplayListener()
        var changes = [QEMUDisplayChange]()
        listener.onChange = { changes.append($0) }

        let shared = try SharedMemory(length: 4096 + 8 * 4 * 4)

        let result = listener.handle(Self.call(
            "ScanoutMap",
            interface: QEMUDisplayListener.sharedMemoryInterface,
            body: [.unixFD(0), .uint32(4096), .uint32(8), .uint32(4), .uint32(32), .uint32(Self.bgrx)],
            fileDescriptors: [shared.descriptor]
        ))
        #expect(Self.succeeded(result))

        let surface = try #require(listener.surface)
        #expect(surface.isShared)
        #expect(surface.width == 8 && surface.height == 4 && surface.bytesPerRow == 32)
        #expect(surface.pixelFormat == .bgrx)
        #expect(Int(bitPattern: surface.memory) % Int(getpagesize()) == 0)
        #expect(surface.memoryLength % Int(getpagesize()) == 0)

        /// What QEMU draws is there without being sent.
        shared.memory.storeBytes(of: UInt32(0xFF11_2233), toByteOffset: 4096 + 32 + 4, as: UInt32.self)
        #expect(surface.pixels.load(fromByteOffset: 32 + 4, as: UInt32.self) == 0xFF11_2233)

        #expect(Self.succeeded(listener.handle(Self.call("UpdateMap", interface: QEMUDisplayListener.sharedMemoryInterface, body: [.int32(6), .int32(-1), .int32(10), .int32(3)]))))

        guard changes.count == 2, case .surface(let shownSurface) = changes[0], case .update(let area) = changes[1] else {
            Issue.record("Unexpected changes: \(changes)")
            return
        }
        #expect(shownSurface === surface)
        #expect(area == CGRect(x: 6, y: 0, width: 2, height: 2))
    }

    @Test func refusesSharedMemoryThatsSmallerThanTheDisplay() throws {
        let listener = QEMUDisplayListener()
        let shared = try SharedMemory(length: 100)

        let result = listener.handle(Self.call(
            "ScanoutMap",
            interface: QEMUDisplayListener.sharedMemoryInterface,
            body: [.unixFD(0), .uint32(0), .uint32(8), .uint32(4), .uint32(32), .uint32(Self.bgrx)],
            fileDescriptors: [shared.descriptor]
        ))

        #expect(!Self.succeeded(result))
        #expect(listener.surface == nil)
    }

    @Test func refusesUnsupportedPixelFormats() throws {
        let listener = QEMUDisplayListener()

        /// 16-bit RGB 565.
        let result = listener.handle(Self.call("Scanout", body: [.uint32(2), .uint32(2), .uint32(4), .uint32(0x1002_0565), .bytes(Data(count: 8))]))

        #expect(!Self.succeeded(result))
        #expect(listener.surface == nil)
    }

    @Test func copiesPixelsThatQEMUSends() throws {
        let listener = QEMUDisplayListener()
        var changes = [QEMUDisplayChange]()
        listener.onChange = { changes.append($0) }

        /// Rows of 3 pixels, with a pixel's worth of padding after each.
        var pixels = Data()
        for row in 0..<2 {
            for column in 0..<4 {
                pixels.append(contentsOf: withUnsafeBytes(of: UInt32(row * 10 + column).littleEndian, Array.init))
            }
        }
        #expect(Self.succeeded(listener.handle(Self.call("Scanout", body: [.uint32(3), .uint32(2), .uint32(16), .uint32(Self.bgrx), .bytes(pixels)]))))

        let surface = try #require(listener.surface)
        #expect(!surface.isShared)
        #expect(surface.bytesPerRow == 12)
        #expect(Self.pixel(surface, x: 2, y: 1) == 12)

        /// An update that's partly outside the display only changes what's inside it.
        let update = Data(withUnsafeBytes(of: UInt32(99).littleEndian, Array.init) + withUnsafeBytes(of: UInt32(98).littleEndian, Array.init))
        #expect(Self.succeeded(listener.handle(Self.call("Update", body: [.int32(2), .int32(0), .int32(2), .int32(1), .uint32(8), .uint32(Self.bgrx), .bytes(update)]))))

        #expect(Self.pixel(surface, x: 1, y: 0) == 1)
        #expect(Self.pixel(surface, x: 2, y: 0) == 99)

        guard changes.count == 2, case .update(let area) = changes[1] else {
            Issue.record("Unexpected changes: \(changes)")
            return
        }
        #expect(area == CGRect(x: 2, y: 0, width: 1, height: 1))

        let image = try #require(surface.makeImage())
        #expect(image.width == 3 && image.height == 2)
    }

    @Test func updatesOnlyApplyToTheKindOfSurfaceTheyreFor() throws {
        let listener = QEMUDisplayListener()
        var changes = [QEMUDisplayChange]()
        listener.onChange = { changes.append($0) }

        #expect(Self.succeeded(listener.handle(Self.call("Scanout", body: [.uint32(2), .uint32(2), .uint32(8), .uint32(Self.bgrx), .bytes(Data(count: 16))]))))
        #expect(Self.succeeded(listener.handle(Self.call("UpdateMap", interface: QEMUDisplayListener.sharedMemoryInterface, body: [.int32(0), .int32(0), .int32(1), .int32(1)]))))

        /// Pixels sent for a different format than the display's are ignored.
        #expect(Self.succeeded(listener.handle(Self.call("Update", body: [.int32(0), .int32(0), .int32(1), .int32(1), .uint32(4), .uint32(0x2003_0888), .bytes(Data(count: 4))]))))

        #expect(changes.count == 1)
    }

    @Test func passesOnThePointer() throws {
        let listener = QEMUDisplayListener()
        var changes = [QEMUDisplayChange]()
        listener.onChange = { changes.append($0) }

        #expect(Self.succeeded(listener.handle(Self.call("CursorDefine", body: [.int32(2), .int32(2), .int32(5), .int32(1), .bytes(Data(count: 16))]))))
        #expect(Self.succeeded(listener.handle(Self.call("MouseSet", body: [.int32(10), .int32(20), .int32(0)]))))

        guard changes.count == 2, case .cursor(let cursor) = changes[0], case .cursorVisibility(let isVisible) = changes[1] else {
            Issue.record("Unexpected changes: \(changes)")
            return
        }
        #expect(cursor.image.width == 2)
        #expect(cursor.hotSpot == CGPoint(x: 1, y: 1))
        #expect(!isVisible)

        /// A pointer whose pixels don't match its size is refused.
        #expect(!Self.succeeded(listener.handle(Self.call("CursorDefine", body: [.int32(2), .int32(2), .int32(0), .int32(0), .bytes(Data(count: 15))]))))
    }

    @Test func turningTheDisplayOffShowsNothing() throws {
        let listener = QEMUDisplayListener()
        var changes = [QEMUDisplayChange]()
        listener.onChange = { changes.append($0) }

        #expect(Self.succeeded(listener.handle(Self.call("Scanout", body: [.uint32(2), .uint32(2), .uint32(8), .uint32(Self.bgrx), .bytes(Data(count: 16))]))))
        #expect(Self.succeeded(listener.handle(Self.call("Disable"))))

        #expect(listener.surface == nil)
        guard case .surface(nil) = changes.last else {
            Issue.record("Unexpected changes: \(changes)")
            return
        }
    }

    @Test func onlyAnswersForTheListener() throws {
        let listener = QEMUDisplayListener()

        guard case .error(let name, _) = listener.handle(Self.call("Explode")) else {
            Issue.record("An unknown method succeeded.")
            return
        }
        #expect(name == "org.freedesktop.DBus.Error.UnknownMethod")

        var elsewhere = Self.call("Disable")
        elsewhere.path = "/org/qemu/Display1/Console_0"
        #expect(!Self.succeeded(listener.handle(elsewhere)))
    }

    @Test func rejectsArgumentsOfTheWrongTypes() throws {
        let listener = QEMUDisplayListener()

        #expect(!Self.succeeded(listener.handle(Self.call("Scanout", body: [.int32(2), .int32(2), .uint32(8), .uint32(Self.bgrx), .bytes(Data(count: 16))]))))
        #expect(!Self.succeeded(listener.handle(Self.call(
            "ScanoutMap",
            interface: QEMUDisplayListener.sharedMemoryInterface,
            body: [.unixFD(3), .uint32(0), .uint32(8), .uint32(4), .uint32(32), .uint32(Self.bgrx)]
        ))))
    }

    // MARK: - Helpers

    private static func call(
        _ member: String,
        interface: String = QEMUDisplayListener.interface,
        body: [DBusValue] = [],
        fileDescriptors: [OwnedFileDescriptor] = []
    ) -> DBusMessage {
        DBusMessage.methodCall(path: QEMUDisplayListener.path, interface: interface, member: member, body: body, fileDescriptors: fileDescriptors)
    }

    private static func succeeded(_ result: DBusConnection.MethodResult) -> Bool {
        if case .reply = result { true } else { false }
    }

    private static func pixel(_ surface: QEMUDisplaySurface, x: Int, y: Int) -> UInt32 {
        surface.pixels.load(fromByteOffset: y * surface.bytesPerRow + x * 4, as: UInt32.self)
    }

    /// Memory that's shared through a file, as QEMU shares a display on the Mac.
    private final class SharedMemory {
        let descriptor: OwnedFileDescriptor
        let memory: UnsafeMutableRawPointer
        let length: Int

        init(length: Int) throws {
            var path = Array("\(NSTemporaryDirectory())display-XXXXXX".utf8CString)
            let descriptor = mkstemp(&path)
            guard descriptor >= 0 else { throw POSIXError.current }
            unlink(String(cString: path))

            self.descriptor = OwnedFileDescriptor(taking: descriptor)
            guard ftruncate(descriptor, off_t(length)) == 0 else { throw POSIXError.current }

            guard let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), memory != MAP_FAILED else {
                throw POSIXError.current
            }
            self.memory = memory
            self.length = length
        }

        deinit {
            munmap(memory, length)
        }
    }
}
