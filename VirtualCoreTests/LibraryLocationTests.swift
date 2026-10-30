import Foundation
import Testing
@testable import VirtualCore

/// Names for virtual machines come from the user, deep links and `vbmcp`, and must always be a location in the library.
@MainActor
struct VirtualMachineNameTests {
    @Test(arguments: ["../Escaped", "Folder/Name", "Name:With:Colons", ".Hidden", "..", "Null\0Name"])
    func namesThatArentInTheLibraryAreRejected(name: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appending(path: "Library", directoryHint: .isDirectory)
        let library = try makeLibrary(at: libraryURL)
        let vm = try VBVirtualMachine(creatingWindowsMachineAt: libraryURL.appending(path: "Windows 11.\(VBVirtualMachine.bundleExtension)", directoryHint: .isDirectory))

        #expect(throws: (any Error).self) { try library.urlForRenaming(vm, to: name) }
        #expect(throws: (any Error).self) { try library.validateNewName(name, for: vm) }
    }

    @Test func plainNamesAreInTheLibrary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appending(path: "Library", directoryHint: .isDirectory)
        let library = try makeLibrary(at: libraryURL)
        let vm = try VBVirtualMachine(creatingWindowsMachineAt: libraryURL.appending(path: "Windows 11.\(VBVirtualMachine.bundleExtension)", directoryHint: .isDirectory))

        let url = try library.urlForRenaming(vm, to: "Clone of Windows 11 (Testing…)")

        #expect(url.lastPathComponent == "Clone of Windows 11 (Testing…).\(VBVirtualMachine.bundleExtension)")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == libraryURL.standardizedFileURL.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "VirtualMachineNameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLibrary(at url: URL) throws -> VMLibraryController {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let defaults = try #require(UserDefaults(suiteName: "VirtualMachineNameTests-\(UUID().uuidString)"))
        defaults.set(url.path, forKey: "libraryPath")

        return VMLibraryController(settingsContainer: VBSettingsContainer(with: defaults))
    }
}

/// The file name of a download comes from its link, which the user may have been given by someone else.
struct DownloadDestinationTests {
    private let downloadsURL = URL(filePath: "/Users/Someone/Library/Application Support/Hypervisaur/_Downloads", directoryHint: .isDirectory)

    @Test func plainFileNamesAreKept() throws {
        let url = try #require(URL(string: "https://updates.cdn-apple.com/2026/macos/UniversalMac_27.1_Restore.ipsw"))

        let destination = try #require(URLSessionDownloadBackend.destinationURL(forDownloadFrom: url, in: downloadsURL))

        #expect(destination.lastPathComponent == "UniversalMac_27.1_Restore.ipsw")
        #expect(destination.deletingLastPathComponent().path == downloadsURL.standardizedFileURL.path)
    }

    @Test(arguments: [
        "https://example.com/files/..%2F..%2F..%2FLaunchAgents%2Fevil.plist",
        "https://example.com/files/%2E%2E",
        "https://example.com/files/.hidden.ipsw",
        "https://example.com/files/a%3Ab.ipsw",
        "https://example.com/",
        "https://example.com/files/evil%00.ipsw",
    ])
    func namesThatArentPlainAreReplacedWithOnesInTheDownloadsFolder(link: String) throws {
        let url = try #require(URL(string: link))

        let destination = try #require(URLSessionDownloadBackend.destinationURL(forDownloadFrom: url, in: downloadsURL))

        #expect(destination.deletingLastPathComponent().path == downloadsURL.standardizedFileURL.path)
        #expect(!destination.lastPathComponent.hasPrefix("."))
        #expect(!destination.lastPathComponent.contains(":"))
    }
}
