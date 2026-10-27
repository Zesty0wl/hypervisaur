import Foundation
import Testing
import BuddyFoundation
@testable import VirtualCore

struct MacReleasesTests {
    // MARK: - AppleDB

    @Test(arguments: [
        ("27.2", "27.2", MacRestoreImageRelease.Kind.release),
        ("27.0.1", "27.0.1", .release),
        ("27.2 RC", "27.2", .releaseCandidate(nil)),
        ("12.6.1 RC 4", "12.6.1", .releaseCandidate(4)),
        ("27.2 beta", "27.2", .beta(1)),
        ("27.2 beta 3", "27.2", .beta(3)),
    ])
    func appleDBVersionsAreRead(version: String, versionString: String, kind: MacRestoreImageRelease.Kind) throws {
        let parsed = try #require(AppleDBMacReleases.parse(version))
        #expect(parsed.versionString == versionString)
        #expect(parsed.kind == kind)
    }

    @Test(arguments: ["26.3 (a)", "26.0 beta SDK", "26.0 RC SDK", "27.2 beta 3 v2", "macOS 27.2"])
    func otherAppleDBEntriesAreLeftOut(version: String) {
        #expect(AppleDBMacReleases.parse(version) == nil)
    }

    @Test func releasesAreNamedLikeTheCatalog() {
        func name(_ versionString: String, _ kind: MacRestoreImageRelease.Kind) -> String {
            MacRestoreImageRelease(build: "26B123", versionString: versionString, kind: kind, url: URL(string: "https://updates.cdn-apple.com/a.ipsw")!, downloadSize: nil, marketingName: nil).name
        }

        #expect(name("27.2", .release) == "macOS 27.2")
        #expect(name("27.0", .release) == "macOS 27.0")
        #expect(name("27.2", .releaseCandidate(nil)) == "macOS 27.2 RC")
        #expect(name("12.6.1", .releaseCandidate(4)) == "macOS 12.6.1 RC 4")
        #expect(name("27.2", .beta(3)) == "macOS 27.2 Developer Beta 3")
    }

    @Test func buildsAreOrderedByVersionThenBetasBeforeReleases() {
        let builds: [(String, SoftwareVersion)] = [
            ("26B123", "27.2"),
            ("26B118", "27.2"),
            ("26B5112a", "27.2"),
            ("26B5101f", "27.2"),
            ("26A434", "27.0.1"),
            ("26A5378n", "27.0"),
            ("26A5378j", "27.0"),
        ]

        for (newer, older) in zip(builds, builds.dropFirst()) {
            #expect(MacRestoreImageRelease.isBuild(newer.0, version: newer.1, newerThan: older.0, version: older.1), "\(newer.0) should be newer than \(older.0)")
            #expect(!MacRestoreImageRelease.isBuild(older.0, version: older.1, newerThan: newer.0, version: newer.1), "\(older.0) shouldn't be newer than \(newer.0)")
        }
    }

    @Test func appleDBListsSignedRestoreImagesForVirtualMachines() throws {
        let releases = try AppleDBMacReleases.releases(from: Data(Self.appleDBList.utf8))

        #expect(releases.map(\.build) == ["26B123", "26B118", "26B5112a"])

        let release = releases[0]
        #expect(release.kind == .release)
        #expect(release.versionString == "27.2")
        #expect(release.url.absoluteString == "https://updates.cdn-apple.com/2026FallFCS/c9671975/UniversalMac_27.2_26B123_Restore.ipsw")
        #expect(release.downloadSize == 25595669503)
        #expect(release.marketingName == "Golden Gate")

        /// The release candidate that turned out to be the release is listed as the release.
        #expect(releases[1].kind == .release)
        #expect(releases[2].kind == .beta(4))
    }

    @Test(arguments: [
        "https://updates.cdn-apple.com/a.ipsw",
        "https://swcdn.apple.com/a.ipsw",
    ])
    func restoreImagesOnApplesServersAreAllowed(url: String) {
        #expect(MacReleaseFinder.isApple(URL(string: url)!))
    }

    @Test(arguments: [
        "http://updates.cdn-apple.com/a.ipsw",
        "https://example.com/updates.cdn-apple.com/a.ipsw",
        "https://notapple.com/a.ipsw",
        "https://updates.cdn-apple.com.example.com/a.ipsw",
    ])
    func restoreImagesElsewhereAreNot(url: String) {
        #expect(!MacReleaseFinder.isApple(URL(string: url)!))
    }

    // MARK: - Catalog

    private static func release(_ build: String, _ versionString: String, _ kind: MacRestoreImageRelease.Kind, marketingName: String? = nil) -> MacRestoreImageRelease {
        MacRestoreImageRelease(
            build: build,
            versionString: versionString,
            kind: kind,
            url: URL(string: "https://updates.cdn-apple.com/2026FallFCS/UniversalMac_\(versionString)_\(build)_Restore.ipsw")!,
            downloadSize: 25_000_000_000,
            marketingName: marketingName
        )
    }

    @Test func newReleasesAreAddedInOrder() throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: .mac)
        let releases = [
            Self.release("26B123", "27.2", .release),
            Self.release("26B5112a", "27.2", .beta(4)),
            Self.release("26B5101f", "27.2", .beta(3)),
            Self.release("26B118", "27.2", .releaseCandidate(nil)),
        ]

        #expect(catalog.releasesMissing(from: releases).map(\.build) == ["26B123", "26B5112a", "26B5101f"])

        let updated = catalog.adding(releases, mobileDeviceMinVersions: ["26B123": "1900"])

        let goldenGate = updated.restoreImages.filter { $0.group == "goldengate" }.map(\.build)
        #expect(Array(goldenGate.prefix(6)) == ["26B123", "26B118", "26B5112a", "26B5101f", "26B5091g", "26B5086k"])

        let release = try #require(updated.restoreImages.first { $0.build == "26B123" })
        #expect(release.name == "macOS 27.2")
        #expect(release.channel == "regular")
        #expect(release.version == "27.2")
        #expect(release.requirements == "min_host_26_virtual_installation")
        #expect(release.mobileDeviceMinVersion == "1900")
        #expect(release.downloadSize == 25_000_000_000)

        /// Without its build manifest, a release needs what the newest image of the same version needs.
        let beta = try #require(updated.restoreImages.first { $0.build == "26B5112a" })
        #expect(beta.channel == "devbeta")
        #expect(beta.name == "macOS 27.2 Developer Beta 4")
        #expect(beta.mobileDeviceMinVersion == "1853")

        #expect(updated.restoreImages.count == catalog.restoreImages.count + 3)
        #expect(updated.groups.map(\.id) == catalog.groups.map(\.id))
    }

    @Test func releaseCandidateThatIsTheReleaseBecomesTheRelease() throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: .mac)

        let updated = catalog.adding([Self.release("26B118", "27.2", .release)], mobileDeviceMinVersions: [:])

        let release = try #require(updated.restoreImages.first { $0.build == "26B118" })
        #expect(release.channel == "regular")
        #expect(release.name == "macOS 27.2")
        #expect(updated.restoreImages.count == catalog.restoreImages.count)
    }

    @Test func newMajorVersionGetsItsOwnGroup() throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: .mac)

        let updated = catalog.adding([Self.release("27A5201k", "28.0", .beta(1))], mobileDeviceMinVersions: ["27A5201k": "1900"])

        let group = try #require(updated.groups.first)
        #expect(group.id == "macos28")
        #expect(group.name == "macOS 28")
        #expect(group.majorVersion == "28")
        #expect(group.image == catalog.groups[0].image)

        let beta = try #require(updated.restoreImages.first)
        #expect(beta.build == "27A5201k")
        #expect(beta.group == "macos28")
        #expect(beta.requirements == catalog.restoreImages[0].requirements)
    }

    @Test func newMajorVersionIsNamedWhenItsNameIsKnown() throws {
        let catalog = try VBAPIClient.fetchBuiltInCatalog(for: .mac)

        let updated = catalog.adding([Self.release("27A400", "28.0", .release, marketingName: "Mojave Sky")], mobileDeviceMinVersions: [:])

        #expect(updated.groups.first?.name == "macOS Mojave Sky")
    }

    // MARK: - Build Manifests

    @Test func buildManifestSaysWhatVirtualMachinesNeed() throws {
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BuildIdentities</key>
            <array>
                <dict>
                    <key>Info</key>
                    <dict>
                        <key>DeviceClass</key><string>j314sap</string>
                        <key>MobileDeviceMinVersion</key><string>1700</string>
                    </dict>
                </dict>
                <dict>
                    <key>Info</key>
                    <dict>
                        <key>DeviceClass</key><string>vma2macosap</string>
                        <key>MobileDeviceMinVersion</key><string>1853</string>
                        <key>VirtualMachineMinHostOS</key><string>13.0.0</string>
                    </dict>
                </dict>
            </array>
            <key>ProductVersion</key><string>27.2</string>
        </dict>
        </plist>
        """

        #expect(try MacBuildManifest(data: Data(manifest.utf8)).mobileDeviceMinVersion == "1853")
    }

    // MARK: - Remote Zip Archives

    @Test(arguments: [["-q"], ["-q", "-fz"], ["-q", "-0"]])
    func filesAreReadFromZipArchives(options: [String]) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacReleasesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = Data((0..<20_000).map { "<string>\($0)</string>\n" }.joined().utf8)
        try manifest.write(to: directory.appending(path: "BuildManifest.plist"))
        try Data("Restore".utf8).write(to: directory.appending(path: "Restore.plist"))

        let archiveURL = directory.appending(path: "Restore.ipsw")
        try run("/usr/bin/zip", options + [archiveURL.path, "Restore.plist", "BuildManifest.plist"], in: directory)

        let data = try Data(contentsOf: archiveURL)
        let archive = RemoteZipArchive(length: UInt64(data.count)) { range in
            data[Int(range.lowerBound)..<Int(range.upperBound)]
        }

        #expect(try await archive.contents(of: "BuildManifest.plist", maximumSize: 1_000_000) == manifest)
        #expect(try await archive.contents(of: "Restore.plist", maximumSize: 1_000_000) == Data("Restore".utf8))

        await #expect(throws: (any Error).self) {
            try await archive.contents(of: "BuildManifest.plist", maximumSize: 1000)
        }
        await #expect(throws: (any Error).self) {
            try await archive.contents(of: "Firmware/missing.im4p", maximumSize: 1_000_000)
        }
    }

    @Test func filesThatArentZipArchivesAreRejected() async {
        let data = Data(repeating: 0x2A, count: 4096)
        let archive = RemoteZipArchive(length: UInt64(data.count)) { range in
            data[Int(range.lowerBound)..<Int(range.upperBound)]
        }

        await #expect(throws: (any Error).self) {
            try await archive.contents(of: "BuildManifest.plist", maximumSize: 1_000_000)
        }
    }

    private func run(_ path: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("\(path) \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus)")
        }
    }

    // MARK: - Sample Data

    /// Entries from AppleDB's list, shortened, with others that aren't restore images that can be installed.
    private static let appleDBList = """
    [
      {
        "osStr": "macOS", "version": "27.2", "build": "26B123", "released": "2026-10-26",
        "appledbWebImage": {"id": "Golden Gate", "align": "left"},
        "signed": ["Mac14,2", "VirtualMac2,1"],
        "sources": [
          {"type": "installassistant", "deviceMap": ["VirtualMac2,1"], "links": [{"url": "https://swcdn.apple.com/content/downloads/InstallAssistant.pkg", "preferred": true, "active": true}]},
          {"type": "ipsw", "deviceMap": ["Mac14,2", "VirtualMac2,1"], "size": 25595669503, "links": [
            {"url": "http://updates-http.cdn-apple.com/2026FallFCS/c9671975/UniversalMac_27.2_26B123_Restore.ipsw", "preferred": false, "active": true},
            {"url": "https://updates.cdn-apple.com/2026FallFCS/c9671975/UniversalMac_27.2_26B123_Restore.ipsw", "preferred": true, "active": true}
          ]}
        ]
      },
      {
        "osStr": "macOS", "version": "27.2 RC", "build": "26B118", "rc": true,
        "signed": ["VirtualMac2,1"],
        "sources": [{"type": "ipsw", "deviceMap": ["VirtualMac2,1"], "links": [{"url": "https://updates.cdn-apple.com/2026FallFCS/UniversalMac_27.2_26B118_Restore.ipsw", "preferred": true, "active": true}]}]
      },
      {
        "osStr": "macOS", "version": "27.2", "build": "26B118", "key": "macOS;26B118-release",
        "signed": ["VirtualMac2,1"],
        "sources": [{"type": "ipsw", "deviceMap": ["VirtualMac2,1"], "links": [{"url": "https://updates.cdn-apple.com/2026FallFCS/UniversalMac_27.2_26B118_Restore.ipsw", "preferred": true, "active": true}]}]
      },
      {
        "osStr": "macOS", "version": "27.2 beta 4", "build": "26B5112a", "beta": true,
        "signed": ["VirtualMac2,1"],
        "sources": [{"type": "ipsw", "deviceMap": ["VirtualMac2,1"], "links": [{"url": "https://updates.cdn-apple.com/2026FallSeed/UniversalMac_27.2_26B5112a_Restore.ipsw", "preferred": true, "active": true}]}]
      },
      {
        "osStr": "macOS", "version": "12.0 beta 2", "build": "21A5268h", "beta": true,
        "signed": [],
        "sources": [{"type": "ipsw", "deviceMap": ["VirtualMac2,1"], "links": [{"url": "https://updates.cdn-apple.com/2021SummerSeed/UniversalMac_12.0_21A5268h_Restore.ipsw", "preferred": true, "active": true}]}]
      },
      {
        "osStr": "macOS", "version": "27.1", "build": "26B50",
        "signed": ["VirtualMac2,1"],
        "sources": [{"type": "ipsw", "deviceMap": ["VirtualMac2,1"], "links": [{"url": "https://example.com/UniversalMac_27.1_26B50_Restore.ipsw", "preferred": true, "active": true}]}]
      },
      {
        "osStr": "macOS", "version": "27.0", "build": "26A99",
        "signed": ["Mac14,2"],
        "sources": [{"type": "ipsw", "deviceMap": ["Mac14,2"], "links": [{"url": "https://updates.cdn-apple.com/2026FallFCS/UniversalMac_27.0_26A99_Restore.ipsw", "preferred": true, "active": true}]}]
      },
      {
        "osStr": "macOS", "version": "26.3 (a)", "build": "25D771280a", "signed": ["VirtualMac2,1"], "sources": []
      },
      {
        "osStr": "macOS", "version": "26.2 SDK", "build": "25C56-26C5038b-SDK", "sources": [{"type": "sdk"}]
      },
      {
        "osStr": "Xcode", "version": "27.2", "build": "17B100"
      },
      "unexpected"
    ]
    """
}
