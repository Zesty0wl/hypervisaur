import Foundation
import Testing
@testable import VirtualCore

struct VMSessionOptionsTests {
    @Test func optionsFromBeforeDisplayOverridesStillDecode() throws {
        let json = Data(#"{"bootInRecoveryMode":false,"bootInDFUMode":false,"bootOnInstallDevice":false,"autoBoot":true}"#.utf8)

        let options = try JSONDecoder().decode(VMSessionOptions.self, from: json)

        #expect(options.autoBoot)
        #expect(options.displayOverride == nil)
    }

    @Test func displayOverridesSurviveEncodingAndDecoding() throws {
        let display = VBDisplayDevice(width: 3024, height: 1890, pixelsPerInch: 254, automaticallyReconfiguresDisplay: true)
        let options = VMSessionOptions(autoBoot: true, displayOverride: display)

        let decoded = try JSONDecoder().decode(VMSessionOptions.self, from: JSONEncoder().encode(options))

        #expect(decoded == options)
        #expect(decoded.displayOverride == display)
    }
}
