import Foundation
import Testing
import BuddyFoundation
@testable import VirtualCore

struct AppReleaseTests {
    private func decode(_ json: String) throws -> AppRelease {
        try JSONDecoder().decode(AppRelease.self, from: Data(json.utf8))
    }

    @Test func releasesAreReadFromGitHub() throws {
        let release = try decode("""
        {
            "tag_name": "v0.10.2",
            "name": "Hypervisaur 0.10.2",
            "html_url": "https://github.com/Zesty0wl/hypervisaur/releases/tag/v0.10.2",
            "draft": false,
            "prerelease": false
        }
        """)

        #expect(release.version == SoftwareVersion(major: 0, minor: 10, patch: 2))
        #expect(release.name == "Hypervisaur 0.10.2")
        #expect(release.pageURL == URL(string: "https://github.com/Zesty0wl/hypervisaur/releases/tag/v0.10.2"))
    }

    @Test func versionsAreComparedAsNumbers() throws {
        let release = try decode(#"{"tag_name": "v0.10.0", "name": "", "html_url": "https://github.com/Zesty0wl/hypervisaur/releases/tag/v0.10.0"}"#)

        #expect(release.version > SoftwareVersion(major: 0, minor: 9, patch: 0))
        #expect(!(release.version > SoftwareVersion(major: 0, minor: 10, patch: 0)))
        #expect(release.name == "Hypervisaur 0.10.0")
    }

    @Test func tagsThatArentVersionsAreRejected() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"tag_name": "nightly", "name": "Nightly", "html_url": "https://github.com/Zesty0wl/hypervisaur/releases/tag/nightly"}"#)
        }
    }
}
