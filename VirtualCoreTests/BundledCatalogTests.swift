import Foundation
import Testing
@testable import VirtualCore

struct BundledCatalogTests {
    @Test(arguments: [VBGuestType.mac, .linux])
    func artworkIsBundledWithTheApp(guest: VBGuestType) throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: guest)

        let urls = catalog.groups.flatMap { group in
            [group.image, group.darkImage].compactMap { $0 }.flatMap { [$0.url, $0.thumbnail.url] }
        }

        #expect(!urls.isEmpty)
        for url in urls {
            #expect(url.isFileURL, "\(url) isn't bundled")
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is missing")
        }
    }

    @Test func legacyGuestAppsComeFromHypervisaursRepository() throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: .mac)

        #expect(!catalog.legacyGuestAppVersions.isEmpty)
        for version in catalog.legacyGuestAppVersions {
            #expect(version.url.absoluteString.hasPrefix(SoftwareCatalog.legacyGuestAppBaseURL.absoluteString))
            #expect(version.url.lastPathComponent == "\(version.id).dmg")
        }
    }

    @Test func remoteServicesAreNotUsed() {
        #expect(!VBAPIClient.isRemoteServiceEnabled)
    }
}
