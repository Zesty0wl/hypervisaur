import Foundation
import System
import Testing
@testable import VirtualCore

@MainActor
struct VirtualBuddyImporterTests {
    @Test func virtualMachineIsCopiedIntoLibraryAndOriginalIsUntouched() async throws {
        let directory = try makeTemporaryDirectory()
        let library = try makeLibrary(at: directory.appending(path: "Library", directoryHint: .isDirectory))
        let sourceURL = directory.appending(path: "Windows 11.vbvm", directoryHint: .isDirectory)
        let source = try VBVirtualMachine(creatingWindowsMachineAt: sourceURL)
        try Data("disk".utf8).write(to: sourceURL.appending(path: "Disk.img"))
        try Data("signed-in\r\n".utf8).write(to: source.windowsGuestStatusURL)
        try Data("1".utf8).write(to: source.qemuPIDFileURL)

        let model = try await VirtualBuddyImporter().importVirtualMachine(from: FilePath(sourceURL.path), into: library)

        #expect(model.bundleURL.lastPathComponent == "Windows 11.\(VBVirtualMachine.bundleExtension)")
        #expect(model.bundleURL.deletingLastPathComponent().standardizedFileURL == library.libraryURL.standardizedFileURL)
        #expect(model.configuration.systemType == .windows)
        #expect(try Data(contentsOf: model.bundleURL.appending(path: "Disk.img")) == Data("disk".utf8))
        #expect(!FileManager.default.fileExists(atPath: model.windowsGuestStatusURL.path))
        #expect(!FileManager.default.fileExists(atPath: model.qemuPIDFileURL.path))

        #expect(FileManager.default.fileExists(atPath: source.windowsGuestStatusURL.path))
        #expect(try Data(contentsOf: sourceURL.appending(path: "Disk.img")) == Data("disk".utf8))
    }

    @Test func existingVirtualMachineIsNotReplaced() async throws {
        let directory = try makeTemporaryDirectory()
        let library = try makeLibrary(at: directory.appending(path: "Library", directoryHint: .isDirectory))
        let sourceURL = directory.appending(path: "Windows 11.vbvm", directoryHint: .isDirectory)
        _ = try VBVirtualMachine(creatingWindowsMachineAt: sourceURL)
        _ = try await VirtualBuddyImporter().importVirtualMachine(from: FilePath(sourceURL.path), into: library)

        await #expect(throws: (any Error).self) {
            _ = try await VirtualBuddyImporter().importVirtualMachine(from: FilePath(sourceURL.path), into: library)
        }
    }

    @Test func folderThatIsNotAVirtualMachineIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        let library = try makeLibrary(at: directory.appending(path: "Library", directoryHint: .isDirectory))
        let sourceURL = directory.appending(path: "Empty.vbvm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            _ = try await VirtualBuddyImporter().importVirtualMachine(from: FilePath(sourceURL.path), into: library)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.libraryURL.path).filter { !$0.hasPrefix(".") }.isEmpty)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "VirtualBuddyImporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLibrary(at url: URL) throws -> VMLibraryController {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let suiteName = "VirtualBuddyImporterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(url.path, forKey: "libraryPath")

        return VMLibraryController(settingsContainer: VBSettingsContainer(with: defaults))
    }
}
