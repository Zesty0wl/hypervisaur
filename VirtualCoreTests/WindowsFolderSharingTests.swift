import Foundation
import Testing
import VirtualWormhole
@testable import VirtualCore

struct WindowsFolderSharingTests {
    /// The test suite from RFC 1320.
    @Test(arguments: [
        ("", "31d6cfe0d16ae931b73c59d7e0c089c0"),
        ("a", "bde52cb31de33e46245e05fbdbd6fb24"),
        ("abc", "a448017aaf21d8525fc10ae87aa6729d"),
        ("message digest", "d9130a8164549fe818874806e1c7014b"),
        ("abcdefghijklmnopqrstuvwxyz", "d79e1c308aa5bbcdeea8ed63df412da9"),
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "043f8582f241db351ce627e153e7f0e4"),
        ("12345678901234567890123456789012345678901234567890123456789012345678901234567890", "e33b4ddc9c38f2199c3e7b164fcc0536"),
    ])
    func md4MatchesTheReferenceDigests(message: String, digest: String) {
        #expect(hex(MD4.hash(Data(message.utf8))) == digest)
    }

    @Test func passwordFileHasTheNTHashOfThePassword() {
        let line = WindowsFolderSharing.passwordFileLine(unixUserName: "neil", userID: 501, password: "test", changed: Date(timeIntervalSince1970: 0x6AE0_C486))

        #expect(line == "neil:501:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:0CB6948805F797BF2A82807973B89537:[UX         ]:LCT-6AE0C486:\n")
    }

    @Test func sharesAreNamedAfterTheirFoldersAsFarAsWindowsAllows() {
        let folders = [
            VBSharedFolder(url: URL(filePath: "/Users/me/Projects")),
            VBSharedFolder(url: URL(filePath: "/Volumes/Work/projects")),
            VBSharedFolder(url: URL(filePath: "/Users/me/Odd: [name], 100% done?")),
            VBSharedFolder(url: URL(filePath: "/Users/me/Global")),
            VBSharedFolder(url: URL(filePath: "/Users/me/Notes"), customMountPointName: "  Notes  "),
        ]

        let shares = WindowsFolderSharing.shares(for: folders)

        #expect(shares.map(\.name) == ["Projects", "projects 2", "Odd_ _name__ 100_ done_", "Global 2", "Notes"])
        #expect(Set(shares.map(\.linkName)).count == shares.count)
        #expect(shares.allSatisfy { $0.linkName.allSatisfy { $0.isHexDigit } })
    }

    @Test func longShareNamesStayWithinWindowsLimit() {
        let name = String(repeating: "a", count: 100)
        let shares = WindowsFolderSharing.shares(for: [
            VBSharedFolder(url: URL(filePath: "/one/\(name)")),
            VBSharedFolder(url: URL(filePath: "/two/\(name)")),
        ])

        #expect(shares.allSatisfy { $0.name.count <= 80 })
        #expect(shares[0].name != shares[1].name)
    }

    @Test func configurationSharesEachFolderWithItsOwnAccess() {
        let directory = URL(filePath: "/tmp/vbq-test/samba", directoryHint: .isDirectory)
        let shares = [
            WindowsFolderSharing.Share(name: "Projects", linkName: "aaaa", url: URL(filePath: "/Users/me/Projects"), isReadOnly: false),
            WindowsFolderSharing.Share(name: "Photos", linkName: "bbbb", url: URL(filePath: "/Users/me/Photos"), isReadOnly: true),
        ]

        let configuration = WindowsFolderSharing.configuration(directoryURL: directory, unixUserName: "me", shares: shares)

        #expect(configuration.contains("[Projects]\npath = /tmp/vbq-test/samba/folders/aaaa\nread only = no\n"))
        #expect(configuration.contains("[Photos]\npath = /tmp/vbq-test/samba/folders/bbbb\nread only = yes\n"))
        #expect(configuration.contains("valid users = me\n"))
        #expect(configuration.contains("server signing = mandatory\n"))
        #expect(configuration.contains("map to guest = never\n"))
        #expect(configuration.contains("passdb backend = smbpasswd:/tmp/vbq-test/samba/private/smbpasswd\n"))
        /// Nothing in the configuration comes from where the folders are, which Samba would expand `%` in.
        #expect(!configuration.contains("/Users/me"))
    }

    @Test func agentIsGivenEachShareInOrder() {
        let sharing = WindowsFolderSharing(
            directoryURL: URL(filePath: "/tmp/vbq-test/samba", directoryHint: .isDirectory),
            serverURL: URL(filePath: "/opt/homebrew/sbin/samba-dot-org-smbd"),
            password: "secret",
            shares: [
                WindowsFolderSharing.Share(name: "Projects", linkName: "aaaa", url: URL(filePath: "/Users/me/Projects"), isReadOnly: false),
                WindowsFolderSharing.Share(name: "Photos", linkName: "bbbb", url: URL(filePath: "/Users/me/Photos"), isReadOnly: true),
            ]
        )

        #expect(sharing.sharedFolders.payload == Data("10.0.2.4\nhypervisaur\nsecret\nProjects\nPhotos".utf8))
        #expect(WindowsFolderSharing.nothingShared.payload == Data("10.0.2.4".utf8))
        #expect(sharing.serverCommand == "'/opt/homebrew/sbin/samba-dot-org-smbd' '--configfile=/tmp/vbq-test/samba/smb.conf'")
    }

    @Test(arguments: [
        GuestSharedFolders(server: "10.0.2.4", credentials: nil, shareNames: []),
        GuestSharedFolders(server: "10.0.2.4", credentials: .init(userName: "hypervisaur", password: "secret"), shareNames: ["Projects", "My Photos"]),
    ])
    func sharedFoldersSurviveTheTripToTheAgent(folders: GuestSharedFolders) throws {
        #expect(try GuestSharedFolders(payload: folders.payload) == folders)
    }

    @Test func sharedFoldersWithoutAPasswordAreRejected() {
        #expect(throws: GuestAgentError.self) { try GuestSharedFolders(payload: Data("10.0.2.4\nhypervisaur".utf8)) }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
