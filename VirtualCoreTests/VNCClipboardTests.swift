import Foundation
import Testing
@testable import VirtualCore

struct VNCClipboardTests {
    @Test func textFromTheGuestHasMacLineEndings() throws {
        /// What zlib makes of a 12 byte text with a terminating null character, as QEMU sends it.
        let payload = Data(hex: "789c636060e0c948cdc9c9e7e52acf2fca4961000020f70460")

        #expect(try VNCClipboard.text(fromProvidePayload: payload) == "hello\nworld")
    }

    @Test func textForTheGuestHasWindowsLineEndingsAndATerminator() throws {
        let payload = try #require(try VNCClipboard.providePayload(for: "a\nb\r\nc"))
        let contents = try ZlibStream.decompress(payload, maximumSize: 1024)

        #expect(contents == Data([0, 0, 0, 8]) + Data("a\r\nb\r\nc".utf8) + Data([0]))
    }

    @Test func textRoundTrips() throws {
        let text = "Café ☕️\nsecond line"
        let payload = try #require(try VNCClipboard.providePayload(for: text))

        #expect(try VNCClipboard.text(fromProvidePayload: payload) == text)
    }

    @Test func textThatsTooLongIsNotShared() throws {
        let text = String(repeating: "a", count: VNCClipboard.maximumTextSize)

        #expect(try VNCClipboard.providePayload(for: text) == nil)
    }

    @Test func messagesUseANegativeLength() {
        let message = VNCClipboard.clientMessage([.notify, .text])

        #expect(message == Data([6, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFC, 0x08, 0x00, 0x00, 0x01]))
    }

    @Test func capabilitiesIncludeTheLargestText() {
        let message = VNCClipboard.capabilitiesMessage

        #expect(message.count == 16)
        #expect(message.bigEndianUInt32(at: 8) == VNCClipboard.Flags([.capabilities, .request, .notify, .provide, .text]).rawValue)
        #expect(message.bigEndianUInt32(at: 12) == UInt32(VNCClipboard.maximumTextSize))
    }

    @Test func checksumMatchesZlib() {
        #expect(ZlibStream.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(ZlibStream.adler32(Data(repeating: 0xFF, count: 100_000)) == 0x149A_302C)
    }

    @Test func damagedDataIsRejected() throws {
        var payload = Data(hex: "789c636060e0c948cdc9c9e7e52acf2fca4961000020f70460")
        payload[payload.count - 1] ^= 0xFF

        #expect(throws: (any Error).self) { try ZlibStream.decompress(payload, maximumSize: 1024) }
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
