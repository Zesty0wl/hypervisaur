import Foundation
import Testing
@testable import VirtualCore

struct DBusMessageTests {
    /// Messages encoded by GLib, which QEMU's D-Bus display is built with.
    private enum GLib {
        static let scanoutMap = "6c01000118000000070000008800000001016f001b0000002f6f72672f71656d752f446973706c6179312f4c697374656e6572000000000002017300230000006f72672e71656d752e446973706c6179312e4c697374656e65722e556e69782e4d6170000000000008016700066875757575750000000000030173000a0000005363616e6f75744d61700000000000000901750001000000000000000010000000050000200300000014000088080220"
        static let getAllReply = "6c0201014800000009000000180000000801670005617b73767d000000000000050175000300000040000000000000000a000000496e746572666163657300026173000028000000230000006f72672e71656d752e446973706c6179312e4c697374656e65722e556e69782e4d617000"
        static let cursorDefineBigEndian = "4201010100000024000001020000007501016f000000001b2f6f72672f71656d752f446973706c6179312f4c697374656e65720000000000020173000000001a6f72672e71656d752e446973706c6179312e4c697374656e657200000000000008016700066969696961790000000000030173000000000c437572736f72446566696e6500000000000000020000000200000001ffffffff000000100102030405060708090a0b0c0d0e0f10"
        static let errorReply = "6c030101120000000a0000003000000004017300170000006f72672e71656d752e446973706c6179312e4572726f7200080167000173000005017500030000000d0000004e6f74206e6f773a206275737900"
    }

    @Test func decodesMethodCallsWithFileDescriptors() throws {
        let pipe = Pipe()
        var requestedDescriptors: Int?

        let message = try DBusMessage.decode(Data(hex: GLib.scanoutMap)) { count in
            requestedDescriptors = count
            return [OwnedFileDescriptor(taking: dup(pipe.fileHandleForReading.fileDescriptor))]
        }

        #expect(requestedDescriptors == 1)
        #expect(message.kind == .methodCall)
        #expect(message.serial == 7)
        #expect(message.path == "/org/qemu/Display1/Listener")
        #expect(message.interface == "org.qemu.Display1.Listener.Unix.Map")
        #expect(message.member == "ScanoutMap")
        #expect(message.signature == "huuuuu")
        #expect(message.body == [.unixFD(0), .uint32(4096), .uint32(1280), .uint32(800), .uint32(5120), .uint32(0x2002_0888)])
        #expect(message.fileDescriptors.count == 1)
    }

    @Test func decodesDictionariesOfVariants() throws {
        let message = try DBusMessage.decode(Data(hex: GLib.getAllReply)) { _ in [] }

        #expect(message.kind == .methodReturn)
        #expect(message.replySerial == 3)
        #expect(message.body == [
            .array(of: .dictEntry(key: .string, value: .variant), [
                .dictEntry(.string("Interfaces"), .variant(.strings(["org.qemu.Display1.Listener.Unix.Map"]))),
            ]),
        ])
    }

    @Test func decodesBigEndianMessages() throws {
        let message = try DBusMessage.decode(Data(hex: GLib.cursorDefineBigEndian)) { _ in [] }

        #expect(message.serial == 258)
        #expect(message.flags.contains(.noReplyExpected))
        #expect(message.member == "CursorDefine")
        #expect(message.body == [.int32(2), .int32(2), .int32(1), .int32(-1), .bytes(Data(1...16))])
    }

    @Test func decodesErrors() throws {
        let message = try DBusMessage.decode(Data(hex: GLib.errorReply)) { _ in [] }

        #expect(message.kind == .error)
        #expect(message.errorName == "org.qemu.Display1.Error")
        #expect(message.replySerial == 3)
        #expect(message.errorMessage == "Not now: busy")
    }

    @Test func messagesSurviveEncodingAndDecoding() throws {
        var message = DBusMessage.methodCall(
            path: "/org/qemu/Display1/Console_0",
            interface: "org.qemu.Display1.Console",
            member: "Everything",
            body: [
                .byte(7),
                .boolean(true),
                .int16(-2),
                .uint16(3),
                .int64(-4_000_000_000),
                .uint64(.max),
                .double(1.5),
                .objectPath("/a/b"),
                .signature("a{sv}"),
                .unixFD(0),
                .bytes(Data([1, 2, 3])),
                .array(of: .structure([.int32, .string]), [.structure([.int32(1), .string("one")]), .structure([.int32(2), .string("two")])]),
                .array(of: .uint64, []),
                .variant(.variant(.string("nested"))),
            ],
            fileDescriptors: [OwnedFileDescriptor(taking: dup(STDIN_FILENO))]
        )
        message.serial = 42

        let data = try message.encoded()
        #expect(try DBusMessage.length(fromFixedHeader: data.prefix(DBusMessage.fixedHeaderLength)) == data.count)

        let decoded = try DBusMessage.decode(data) { count in
            (0..<count).map { _ in OwnedFileDescriptor(taking: dup(STDIN_FILENO)) }
        }

        #expect(decoded.serial == 42)
        #expect(decoded.path == message.path)
        #expect(decoded.interface == message.interface)
        #expect(decoded.member == message.member)
        #expect(decoded.body == message.body)
        #expect(decoded.fileDescriptors.count == 1)
    }

    @Test func repliesReferToTheirCall() throws {
        var call = DBusMessage.methodCall(path: "/", interface: "a.b", member: "C")
        call.serial = 5

        var reply = call.reply([.string("done")])
        reply.serial = 6
        let decoded = try DBusMessage.decode(try reply.encoded()) { _ in [] }

        #expect(decoded.kind == .methodReturn)
        #expect(decoded.replySerial == 5)
        #expect(decoded.body == [.string("done")])
    }

    @Test func parsesSignatures() throws {
        #expect(try DBusType.types(in: "") == [])
        #expect(try DBusType.types(in: "iu") == [.int32, .uint32])
        #expect(try DBusType.types(in: "a{sv}") == [.array(.dictEntry(key: .string, value: .variant))])
        #expect(try DBusType.types(in: "(i(ay))") == [.structure([.int32, .structure([.array(.byte)])])])

        for invalid in ["a", "(", "()", "{sv}", "a{vs}", "a{s}", "z", String(repeating: "a", count: 33) + "y"] {
            #expect(throws: DBusError.self, "\(invalid)") { try DBusType.types(in: invalid) }
        }
    }

    @Test func rejectsMalformedMessages() throws {
        let valid = Data(hex: GLib.errorReply)

        /// Cut short.
        #expect(throws: (any Error).self) { try DBusMessage.decode(valid.dropLast()) { _ in [] } }

        /// A body that's longer than its signature says.
        var longBody = valid
        longBody[4] += 1
        longBody.append(0)
        #expect(throws: (any Error).self) { try DBusMessage.decode(longBody) { _ in [] } }

        /// A string that doesn't end in a null character.
        var unterminated = valid
        unterminated[unterminated.count - 1] = 0x41
        #expect(throws: (any Error).self) { try DBusMessage.decode(unterminated) { _ in [] } }

        /// An unknown byte order.
        var byteOrder = valid
        byteOrder[0] = 0x58
        #expect(throws: (any Error).self) { try DBusMessage.decode(byteOrder) { _ in [] } }

        /// A message that says more file descriptors came with it than did.
        #expect(throws: (any Error).self) {
            try DBusMessage.decode(Data(hex: GLib.scanoutMap)) { _ in throw DBusError.malformedMessage("No descriptors.") }
        }
    }

    @Test func rejectsMessagesThatAreTooLong() throws {
        var header = Data(hex: GLib.errorReply).prefix(DBusMessage.fixedHeaderLength)
        header.replaceSubrange(4..<8, with: [0xff, 0xff, 0xff, 0x7f])

        #expect(throws: DBusError.self) { try DBusMessage.length(fromFixedHeader: header) }
    }

    @Test func rejectsBooleansThatArentZeroOrOne() throws {
        var encoder = DBusEncoder()
        try encoder.encode(.uint32(2))

        var decoder = DBusDecoder(data: encoder.data, isLittleEndian: true)
        #expect(throws: DBusError.self) { try decoder.decode(.boolean) }
    }

    @Test func rejectsArraysOfTheWrongType() throws {
        var encoder = DBusEncoder()
        #expect(throws: DBusError.self) { try encoder.encode(.array(of: .string, [.int32(1)])) }
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
