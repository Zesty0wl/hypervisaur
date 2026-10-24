import Foundation
import Testing
@testable import VirtualCore

struct VMProcessInspectorTests {
    private let bundleURL = FileManager.default.temporaryDirectory.appending(path: "VMProcessInspectorTests-\(UUID().uuidString).hypervisaur")

    @Test func processesAreFoundByTheFilesTheyHaveOpen() throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let diskURL = bundleURL.appending(path: "Disk.img")
        FileManager.default.createFile(atPath: diskURL.path, contents: Data(count: 4096))
        let disk = try FileHandle(forReadingFrom: diskURL)

        let me = ProcessInfo.processInfo.processIdentifier
        let other = bundleURL.deletingLastPathComponent().appending(path: "Other-\(UUID().uuidString).hypervisaur")

        #expect(VMProcessInspector.process(forBundleAt: bundleURL, among: [me]) == me)
        #expect(VMProcessInspector.process(forBundleAt: other, among: [me]) == nil)

        try disk.close()

        #expect(!VMProcessInspector.isProcess(me, runningBundleAt: bundleURL))
    }

    @Test func processorTimeIsMeasuredInNanoseconds() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let before = try #require(VMProcessInspector.sample(me))

        let clock = ContinuousClock()
        let start = clock.now
        var value: UInt64 = 0
        while clock.now - start < .milliseconds(300) {
            value = value &* 6364136223846793005 &+ 1442695040888963407
        }
        #expect(value != 0)

        let after = try #require(VMProcessInspector.sample(me))
        let used = after.processorTime - before.processorTime

        /// The loop keeps one core busy, so the time used is close to how long it ran, with room for other tests running alongside.
        #expect(used >= .milliseconds(200))
        #expect(used < .seconds(30))
        #expect(after.memoryFootprint > 0)
    }

    @Test func processesThatDontExistArentSampled() {
        #expect(VMProcessInspector.sample(-1) == nil)
    }
}
