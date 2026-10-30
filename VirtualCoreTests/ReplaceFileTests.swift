import Foundation
import Testing
@testable import VirtualCore

/// Files saved to a path someone else chose, such as a screenshot that `vbmcp` is asked to save, mustn't remove what's there.
final class ReplaceFileTests {
    private let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "ReplaceFileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    @Test func newFilesAreWritten() throws {
        let url = directoryURL.appending(path: "Screenshot.png")

        try FileManager.default.replaceRegularFile(at: url, with: Data("new".utf8))

        #expect(try Data(contentsOf: url) == Data("new".utf8))
    }

    @Test func filesThatAreThereAreReplaced() throws {
        let url = directoryURL.appending(path: "Screenshot.png")
        try Data("old".utf8).write(to: url)

        try FileManager.default.replaceRegularFile(at: url, with: Data("new".utf8))

        #expect(try Data(contentsOf: url) == Data("new".utf8))
    }

    @Test func foldersAreLeftAsTheyWere() throws {
        let folder = directoryURL.appending(path: "Documents.png", directoryHint: .isDirectory)
        let inside = folder.appending(path: "Important.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: inside)

        #expect(throws: (any Error).self) {
            try FileManager.default.replaceRegularFile(at: folder, with: Data("new".utf8))
        }

        #expect(try Data(contentsOf: inside) == Data("keep".utf8))
    }

    @Test func symbolicLinksAndWhatTheyPointToAreLeftAsTheyWere() throws {
        let target = directoryURL.appending(path: "Target.txt")
        let link = directoryURL.appending(path: "Link.png")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try FileManager.default.replaceRegularFile(at: link, with: Data("new".utf8))
        }

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }
}
