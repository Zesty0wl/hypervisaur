import Foundation
import Testing
@testable import VirtualCore

struct CatalogReleaseResolverTests {
    @Test func newestPointReleaseIsFirstInAChecksumList() throws {
        let index = URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/SHA256SUMS")!
        let list = """
        c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57 *ubuntu-26.04-desktop-arm64.iso
        c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517 *ubuntu-26.04.1-desktop-arm64.iso
        2be09ca883921bff6d8e6b0bfbafd13e32436553b7086f33bce3a4c5bad8bd14 *ubuntu-26.04.1-live-server-arm64.iso
        """

        let images = CatalogReleaseResolver.images(in: list, listedAt: index, matching: try Regex(#"ubuntu-26\.04(\.\d+)?-desktop-arm64\.iso"#))

        #expect(images.map(\.absoluteString) == [
            "https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso",
            "https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04-desktop-arm64.iso",
        ])
    }

    @Test func versionsAreComparedAsNumbers() throws {
        let index = URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/SHA256SUMS")!
        let list = """
        8a205a71b64d4e1667adcdb4b3c4e7dce914845e8afdca5a189972b06f92f9d7  debian-13.7.0-arm64-DVD-1.iso
        59d4be8a4e97fea211a0876dd5fe565a9ba88800756ddf57ec0d383b49c8a8ce  debian-13.10.0-arm64-DVD-1.iso
        239600395ddb0f9baf5287565c5a3040269f17f9f5aca73b66372218850b0fb4  debian-13.10.0-arm64-DVD-10.iso
        """

        let images = CatalogReleaseResolver.images(in: list, listedAt: index, matching: try Regex(#"debian-13\.\d+\.\d+-arm64-DVD-1\.iso"#))

        #expect(images.map(\.lastPathComponent) == ["debian-13.10.0-arm64-DVD-1.iso", "debian-13.7.0-arm64-DVD-1.iso"])
    }

    @Test func imagesAreFoundInADirectoryListing() throws {
        let index = URL(string: "https://cdimage.kali.org/current/")!
        let list = """
        <tr><td><a href="kali-linux-2026.3-installer-arm64.iso">kali-linux-2026.3-installer-arm64.iso</a></td></tr>
        <tr><td><a href="kali-linux-2026.3-installer-arm64.iso.torrent">kali-linux-2026.3-installer-arm64.iso.torrent</a></td></tr>
        """

        let images = CatalogReleaseResolver.images(in: list, listedAt: index, matching: try Regex(#"kali-linux-\d{4}\.\d+[a-z]?-installer-arm64\.iso"#))

        #expect(images.map(\.absoluteString) == ["https://cdimage.kali.org/current/kali-linux-2026.3-installer-arm64.iso"])
    }

    @Test func imagesAreFoundByURLInAReleaseList() throws {
        let index = URL(string: "https://fedoraproject.org/releases.json")!
        let list = """
        [
          {"version": "45 Beta", "arch": "aarch64", "link": "https://download.fedoraproject.org/pub/fedora/linux/releases/test/45_Beta/Everything/aarch64/iso/Fedora-Everything-netinst-aarch64-45_Beta-1.3.iso"},
          {"version": "44", "arch": "aarch64", "link": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/iso/Fedora-Everything-netinst-aarch64-44-1.7.iso"},
          {"version": "43", "arch": "aarch64", "link": "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Everything/aarch64/iso/Fedora-Everything-netinst-aarch64-43-1.6.iso"},
          {"version": "44", "arch": "x86_64", "link": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-44-1.7.iso"}
        ]
        """

        let images = CatalogReleaseResolver.images(in: list, listedAt: index, matching: try Regex(#"Fedora-Everything-netinst-aarch64-\d+-[\d.]+\.iso"#))

        #expect(images.map(\.absoluteString) == [
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/iso/Fedora-Everything-netinst-aarch64-44-1.7.iso",
            "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Everything/aarch64/iso/Fedora-Everything-netinst-aarch64-43-1.6.iso",
        ])
    }

    @Test func imagesThatArentDownloadedSecurelyAreIgnored() throws {
        let index = URL(string: "https://example.com/SHA256SUMS")!
        let list = "http://example.com/images/debian-13.8.0-arm64-DVD-1.iso debian-13.7.0-arm64-DVD-1.iso"

        let images = CatalogReleaseResolver.images(in: list, listedAt: index, matching: try Regex(#"debian-13\.\d+\.\d+-arm64-DVD-1\.iso"#))

        #expect(images.map(\.absoluteString) == ["https://example.com/debian-13.7.0-arm64-DVD-1.iso"])
    }

    @Test func fileNamesMatchTheWholePattern() {
        let source = CatalogReleaseSource(indexes: [], fileNamePattern: #"debian-13\.\d+\.\d+-arm64-DVD-1\.iso"#)

        #expect(source.matches(fileName: "debian-13.7.0-arm64-DVD-1.iso"))
        #expect(!source.matches(fileName: "debian-13.7.0-arm64-DVD-10.iso"))
        #expect(!source.matches(fileName: "debian-13.7.0-arm64-DVD-1.iso.part"))
    }

    @Test func linuxImagesFollowTheirRelease() throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: .linux)

        #expect(!catalog.restoreImages.isEmpty)
        for image in catalog.restoreImages {
            let source = try #require(image.releaseSource, "\(image.name) doesn't follow its release")

            #expect(!source.indexes.isEmpty)
            #expect(source.indexes.allSatisfy { $0.scheme == "https" })
            #expect(source.matches(fileName: image.url.lastPathComponent), "\(image.name)'s image doesn't match its release")
        }
    }

    @Test func betasAreInPrereleaseChannels() throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: .mac)

        let channels = Dictionary(uniqueKeysWithValues: catalog.channels.map { ($0.id, $0) })
        #expect(channels["devbeta"]?.isPrerelease == true)
        #expect(channels["regular"]?.isPrerelease == false)
    }
}
