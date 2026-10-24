import Foundation
import Testing
@testable import VirtualWormhole

/// A folder for a test, removed afterwards.
private final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "GuestFileTransferTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ path: String, _ data: Data, permissions: Int? = nil, modified: Date? = nil) throws -> URL {
        let fileURL = url.appending(path: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
        var attributes = [FileAttributeKey: Any]()
        if let permissions { attributes[.posixPermissions] = permissions }
        if let modified { attributes[.modificationDate] = modified }
        if !attributes.isEmpty { try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path) }
        return fileURL
    }

    var contents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path).sorted()) ?? []
    }
}

private func randomData(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

/// Frames that a test's transfers sent, which arrive on other threads.
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = [GuestAgentFrame]()

    func append(_ frame: GuestAgentFrame) {
        lock.withLock { frames.append(frame) }
    }

    var all: [GuestAgentFrame] { lock.withLock { frames } }

    func wait(timeout: Duration = .seconds(5), until condition: ([GuestAgentFrame]) -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(all) {
            guard clock.now < deadline else { throw GuestAgentError("Timed out waiting for frames.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

struct GuestFileTransferTests {
    @Test func filesAndFoldersArriveAsTheyWereSent() throws {
        let source = try TemporaryFolder()
        let destination = try TemporaryFolder()
        let modified = Date(timeIntervalSince1970: 1_700_000_000)

        let note = try source.file("Note.txt", Data("hello".utf8), permissions: 0o640, modified: modified)
        let empty = try source.file("Empty", Data())
        let large = randomData(GuestAgentFrame.fileChunkSize * 3 + 123)
        try source.file("Photos/1.jpg", randomData(300_000))
        try source.file("Photos/Raw/2.dng", large, permissions: 0o755)
        let photos = source.url.appending(path: "Photos")

        let sender = try GuestFileSender(urls: [note, empty, photos])
        let receiver = GuestFileReceiver(rootURL: destination.url)

        try sender.send { kind, payload in
            if let acknowledgement = try receiver.receive(GuestAgentFrame(kind, channel: 1, payload: payload)) {
                sender.acknowledge(acknowledgement)
            }
        }

        #expect(receiver.isComplete)
        #expect(receiver.size == GuestTransferSize(totalBytes: 5 + 300_000 + UInt64(large.count), itemCount: 6))
        #expect(receiver.writtenBytes == 5 + 300_000 + UInt64(large.count))
        #expect(receiver.topLevelURLs.map(\.lastPathComponent) == ["Note.txt", "Empty", "Photos"])
        #expect(destination.contents == ["Empty", "Note.txt", "Photos"])

        let copiedNote = destination.url.appending(path: "Note.txt")
        #expect(try Data(contentsOf: copiedNote) == Data("hello".utf8))
        #expect(try Data(contentsOf: destination.url.appending(path: "Photos/Raw/2.dng")) == large)
        #expect(try Data(contentsOf: destination.url.appending(path: "Empty")).isEmpty)

        let attributes = try FileManager.default.attributesOfItem(atPath: copiedNote.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o640)
        #expect((attributes[.modificationDate] as? Date) == modified)

        let raw = try FileManager.default.attributesOfItem(atPath: destination.url.appending(path: "Photos/Raw/2.dng").path)
        #expect((raw[.posixPermissions] as? Int) == 0o755)
    }

    @Test func topLevelItemsCanBeRenamed() throws {
        let source = try TemporaryFolder()
        let destination = try TemporaryFolder()
        try source.file("Holiday/1.jpg", Data("one".utf8))

        let sender = try GuestFileSender(urls: [source.url.appending(path: "Holiday")])
        let receiver = GuestFileReceiver(rootURL: destination.url) { _ in "Holiday 2" }

        try sender.send { kind, payload in
            if let acknowledgement = try receiver.receive(GuestAgentFrame(kind, channel: 1, payload: payload)) {
                sender.acknowledge(acknowledgement)
            }
        }

        #expect(try Data(contentsOf: destination.url.appending(path: "Holiday 2/1.jpg")) == Data("one".utf8))
    }

    @Test(arguments: ["../escape", "/etc/passwd", "a/../b", "a//b", "./a", "", "a/"])
    func pathsOutsideTheTransferAreRejected(path: String) throws {
        let destination = try TemporaryFolder()
        let receiver = GuestFileReceiver(rootURL: destination.url)
        let header = GuestFileHeader(type: .file, size: 0, permissions: 0, modificationTime: 0, path: path)

        #expect(throws: GuestAgentError.self) {
            try receiver.receive(GuestAgentFrame(.fileHeader, channel: 1, payload: header.payload))
        }
        #expect(destination.contents.isEmpty)
    }

    @Test func itemsMustBeInsideAFolderThatCameBefore() throws {
        let destination = try TemporaryFolder()
        let receiver = GuestFileReceiver(rootURL: destination.url)
        let file = GuestFileHeader(type: .file, size: 0, permissions: 0, modificationTime: 0, path: "Note.txt")
        let inside = GuestFileHeader(type: .file, size: 0, permissions: 0, modificationTime: 0, path: "Note.txt/Inside.txt")
        let unknown = GuestFileHeader(type: .file, size: 0, permissions: 0, modificationTime: 0, path: "Missing/Inside.txt")

        _ = try receiver.receive(GuestAgentFrame(.fileHeader, channel: 1, payload: file.payload))

        #expect(throws: GuestAgentError.self) { try receiver.receive(GuestAgentFrame(.fileHeader, channel: 1, payload: inside.payload)) }
        #expect(throws: GuestAgentError.self) { try receiver.receive(GuestAgentFrame(.fileHeader, channel: 1, payload: unknown.payload)) }
    }

    @Test func moreDataThanTheFileHasIsRejected() throws {
        let destination = try TemporaryFolder()
        let receiver = GuestFileReceiver(rootURL: destination.url)
        let header = GuestFileHeader(type: .file, size: 3, permissions: 0, modificationTime: 0, path: "Short.txt")

        _ = try receiver.receive(GuestAgentFrame(.fileHeader, channel: 1, payload: header.payload))

        #expect(throws: GuestAgentError.self) { try receiver.receive(GuestAgentFrame(.fileData, channel: 1, payload: Data("toolong".utf8))) }
    }

    @Test func senderWaitsForAcknowledgements() async throws {
        let source = try TemporaryFolder()
        let file = try source.file("Large.bin", randomData(Int(GuestAgentFrame.transferWindow) * 3))
        let sender = try GuestFileSender(urls: [file])

        let sentBytes = LockedBox(0)
        let outcome = LockedBox<Result<Void, Error>?>(nil)

        let thread = Thread {
            do {
                try sender.send { kind, payload in
                    if kind == .fileData { sentBytes.withValue { $0 += payload.count } }
                }
                outcome.withValue { $0 = .success(()) }
            } catch {
                outcome.withValue { $0 = .failure(error) }
            }
        }
        thread.start()

        try await Task.sleep(for: .milliseconds(300))
        #expect(sentBytes.value <= Int(GuestAgentFrame.transferWindow))
        #expect(outcome.value == nil)

        sender.acknowledge(GuestAgentFrame.transferWindow)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sentBytes.value > Int(GuestAgentFrame.transferWindow))
        #expect(sentBytes.value <= Int(GuestAgentFrame.transferWindow) * 2)

        sender.cancel()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while outcome.value == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .failure(let error) = outcome.value else {
            Issue.record("The transfer should have been cancelled.")
            return
        }
        #expect(error is CancellationError)
    }

    @Test func dragItemsSurviveEncodingAndDecoding() {
        let items = [
            GuestDragItem(isFolder: false, path: #"C:\Users\neil\Desktop\Report.pdf"#),
            GuestDragItem(isFolder: true, path: "/Users/neil/Pictures/Holiday"),
        ]

        #expect(GuestDragItem.items(from: GuestDragItem.payload(for: items)) == items)
        #expect(items.map(\.name) == ["Report.pdf", "Holiday"])
        #expect(GuestDragItem.items(from: Data()).isEmpty)
    }
}

struct GuestAgentFileTransfersTests {
    private func makeTransfers(desktop: TemporaryFolder, collector: FrameCollector) -> GuestAgentFileTransfers {
        let desktopURL = desktop.url
        return GuestAgentFileTransfers(desktopURL: { desktopURL }) { collector.append($0) }
    }

    /// Sends files to the agent as the Mac does, acknowledging nothing, since the test sends far less than the window.
    private func put(_ urls: [URL], channel: UInt32, to transfers: GuestAgentFileTransfers) throws {
        #expect(transfers.handle(GuestAgentFrame(.putFiles, channel: channel, payload: Data([GuestFileDestination.desktop.rawValue]))))
        let sender = try GuestFileSender(urls: urls)
        try sender.send { kind, payload in
            _ = transfers.handle(GuestAgentFrame(kind, channel: channel, payload: payload))
        }
    }

    @Test func filesArePutOnTheDesktopWithNamesThatArentTaken() async throws {
        let desktop = try TemporaryFolder()
        let source = try TemporaryFolder()
        try desktop.file("Note.txt", Data("already here".utf8))
        let note = try source.file("Note.txt", Data("new".utf8))
        try source.file("Holiday/1.jpg", Data("one".utf8))

        let collector = FrameCollector()
        let transfers = makeTransfers(desktop: desktop, collector: collector)

        try put([note, source.url.appending(path: "Holiday")], channel: 7, to: transfers)
        try await collector.wait { $0.contains { $0.kind == .transferred || $0.kind == .failed } }

        let reply = try #require(collector.all.last)
        #expect(reply.kind == .transferred)
        #expect(reply.channel == 7)
        #expect(reply.pathList.map { URL(fileURLWithPath: $0).lastPathComponent } == ["Note 2.txt", "Holiday"])

        #expect(desktop.contents == ["Holiday", "Note 2.txt", "Note.txt"])
        #expect(try Data(contentsOf: desktop.url.appending(path: "Note 2.txt")) == Data("new".utf8))
        #expect(try Data(contentsOf: desktop.url.appending(path: "Note.txt")) == Data("already here".utf8))
        #expect(collector.all.contains { $0.kind == .acknowledge })
    }

    @Test func cancelledTransfersLeaveNothingBehind() async throws {
        let desktop = try TemporaryFolder()
        let collector = FrameCollector()
        let transfers = makeTransfers(desktop: desktop, collector: collector)

        let header = GuestFileHeader(type: .file, size: 100, permissions: 0, modificationTime: 0, path: "Partial.bin")
        _ = transfers.handle(GuestAgentFrame(.putFiles, channel: 3, payload: Data([0])))
        _ = transfers.handle(GuestAgentFrame(.transferSize, channel: 3, payload: GuestTransferSize(totalBytes: 100, itemCount: 1).payload))
        _ = transfers.handle(GuestAgentFrame(.fileHeader, channel: 3, payload: header.payload))
        _ = transfers.handle(GuestAgentFrame(.fileData, channel: 3, payload: Data(count: 10)))
        #expect(transfers.handle(GuestAgentFrame(.terminate, channel: 3)))

        try await collector.wait { $0.contains { $0.kind == .failed } }

        #expect(collector.all.last?.text == "Cancelled.")
        #expect(desktop.contents.isEmpty)
    }

    @Test func filesAreSentFromTheGuest() async throws {
        let source = try TemporaryFolder()
        let destination = try TemporaryFolder()
        let desktop = try TemporaryFolder()
        let data = randomData(Int(GuestAgentFrame.transferWindow) + 1000)
        try source.file("Holiday/1.jpg", data)

        let receiver = GuestFileReceiver(rootURL: destination.url)
        let receiverLock = NSLock()
        let ended = LockedBox(false)
        let failure = LockedBox<String?>(nil)

        let transfersBox = LockedBox<GuestAgentFileTransfers?>(nil)
        let desktopURL = desktop.url
        let transfers = GuestAgentFileTransfers(desktopURL: { desktopURL }) { frame in
            /// The Mac acknowledges what it writes, which lets the agent send more than the window.
            do {
                if frame.kind == .failed { failure.withValue { $0 = frame.text } }
                let acknowledgement = try receiverLock.withLock { try receiver.receive(frame) }
                if frame.kind == .filesEnd { ended.withValue { $0 = true } }
                if let acknowledgement {
                    _ = transfersBox.value?.handle(GuestAgentFrame(.acknowledge, channel: frame.channel, payload: GuestAgentFrame.acknowledgement(acknowledgement)))
                }
            } catch {
                failure.withValue { $0 = error.localizedDescription }
            }
        }
        transfersBox.withValue { $0 = transfers }

        #expect(transfers.handle(GuestAgentFrame(.getFiles, channel: 9, payload: GuestAgentFrame.pathList([source.url.appending(path: "Holiday").path]))))

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !ended.value, failure.value == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(failure.value == nil)
        #expect(ended.value)
        #expect(try Data(contentsOf: destination.url.appending(path: "Holiday/1.jpg")) == data)
    }

    @Test func dragsWithoutACatcherFail() async throws {
        let desktop = try TemporaryFolder()
        let collector = FrameCollector()
        let transfers = makeTransfers(desktop: desktop, collector: collector)

        #expect(transfers.handle(GuestAgentFrame(.catchDrag, channel: 4)))
        try await collector.wait { !$0.isEmpty }
        #expect(collector.all.first?.kind == .failed)
    }

    @MainActor
    @Test func dragsAreCaughtByTheGuestApp() async throws {
        let desktop = try TemporaryFolder()
        let collector = FrameCollector()
        let transfers = makeTransfers(desktop: desktop, collector: collector)
        transfers.dragCatcher = { [GuestDragItem(isFolder: true, path: "/Users/neil/Pictures/Holiday")] }

        #expect(transfers.handle(GuestAgentFrame(.catchDrag, channel: 4)))
        try await collector.wait { !$0.isEmpty }

        let reply = try #require(collector.all.first)
        #expect(reply.kind == .dragItems)
        #expect(GuestDragItem.items(from: reply.payload) == [GuestDragItem(isFolder: true, path: "/Users/neil/Pictures/Holiday")])
    }
}

/// A value shared between a test and the threads it starts.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value { lock.withLock { storage } }

    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&storage) }
    }
}
