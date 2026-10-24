import Foundation
import Testing
@testable import VirtualCore
import VirtualWormhole

/// An agent that runs in the test instead of a guest. It puts files it receives in `desktopURL`, sends files from the Mac's
/// own disk, and catches drags with `dragItems`.
private final class FakeFileAgent: GuestAgentTransport, @unchecked Sendable {
    let desktopURL: URL
    let protocolVersion: UInt32
    var dragItems: [GuestDragItem]?
    /// Without acknowledgements, the Mac stops sending once it has sent the window, as it would to a guest that's slow to write.
    var acknowledges = true

    private let queue = DispatchQueue(label: "FakeFileAgent")
    private let lock = NSLock()
    private var onFrame: (@Sendable (GuestAgentFrame) -> Void)?
    private var receivers = [UInt32: GuestFileReceiver]()
    private var senders = [UInt32: GuestFileSender]()

    init(desktopURL: URL, protocolVersion: UInt32 = GuestAgentFrame.fileTransferProtocolVersion) {
        self.desktopURL = desktopURL
        self.protocolVersion = protocolVersion
    }

    func start(onFrame: @escaping @Sendable (GuestAgentFrame) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { self.onFrame = onFrame }
    }

    func send(_ frame: GuestAgentFrame) throws {
        queue.async { self.handle(frame) }
    }

    func close() { }

    private func reply(_ kind: GuestAgentFrame.Kind, _ channel: UInt32, _ payload: Data = Data()) {
        lock.withLock { onFrame }?(GuestAgentFrame(kind, channel: channel, payload: payload))
    }

    private func handle(_ frame: GuestAgentFrame) {
        switch frame.kind {
        case .reset:
            reply(.hello, 0, GuestAgentInfo(protocolVersion: protocolVersion, system: "Test").payload)
        case .putFiles:
            receivers[frame.channel] = GuestFileReceiver(rootURL: desktopURL)
        case .transferSize, .fileHeader, .fileData, .filesEnd:
            guard let receiver = receivers[frame.channel] else { return }
            do {
                if let acknowledgement = try receiver.receive(frame), acknowledges {
                    reply(.acknowledge, frame.channel, GuestAgentFrame.acknowledgement(acknowledgement))
                }
                if receiver.isComplete {
                    receivers[frame.channel] = nil
                    reply(.transferred, frame.channel, GuestAgentFrame.pathList(receiver.topLevelURLs.map(\.path)))
                }
            } catch {
                receivers[frame.channel] = nil
                reply(.failed, frame.channel, Data(error.localizedDescription.utf8))
            }
        case .terminate:
            if receivers.removeValue(forKey: frame.channel) != nil {
                reply(.failed, frame.channel, Data("Cancelled.".utf8))
            }
            lock.withLock { senders.removeValue(forKey: frame.channel) }?.cancel()
        case .getFiles:
            let channel = frame.channel
            do {
                let sender = try GuestFileSender(urls: frame.pathList.map { URL(fileURLWithPath: $0) })
                lock.withLock { senders[channel] = sender }
                Thread {
                    try? sender.send { kind, payload in self.reply(kind, channel, payload) }
                }.start()
            } catch {
                reply(.failed, channel, Data(error.localizedDescription.utf8))
            }
        case .acknowledge:
            if let bytes = frame.acknowledgedBytes {
                lock.withLock { senders[frame.channel] }?.acknowledge(bytes)
            }
        case .catchDrag:
            if let dragItems {
                reply(.dragItems, frame.channel, GuestDragItem.payload(for: dragItems))
            }
        default:
            break
        }
    }
}

private final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "GuestFileTransferOperationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Progress reports, which arrive on other threads.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports = [GuestFileTransferOperation.Progress]()

    func append(_ progress: GuestFileTransferOperation.Progress) {
        lock.withLock { reports.append(progress) }
    }

    var all: [GuestFileTransferOperation.Progress] { lock.withLock { reports } }
}

struct GuestFileTransferOperationTests {
    private func connect(_ agent: FakeFileAgent) async throws -> GuestAgentConnection {
        let connection = GuestAgentConnection(transport: agent, guestName: "Test")
        connection.start()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while connection.info == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return connection
    }

    @Test func filesArePutInTheGuest() async throws {
        let source = try TemporaryFolder()
        let desktop = try TemporaryFolder()
        let data = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let fileURL = source.url.appending(path: "Large.bin")
        try data.write(to: fileURL)

        let connection = try await connect(FakeFileAgent(desktopURL: desktop.url))
        let log = ProgressLog()

        let paths = try await GuestFileTransferOperation(.toGuest([fileURL]), connection: connection).run { log.append($0) }

        #expect(paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["Large.bin"])
        #expect(try Data(contentsOf: desktop.url.appending(path: "Large.bin")) == data)
        #expect(log.all.first?.completedBytes == 0)
        #expect(log.all.last?.completedBytes == UInt64(data.count))
        #expect(log.all.allSatisfy { $0.totalBytes == UInt64(data.count) })
    }

    @Test func filesAreCopiedFromTheGuest() async throws {
        let guestFolder = try TemporaryFolder()
        let destination = try TemporaryFolder()
        let holiday = guestFolder.url.appending(path: "Holiday")
        try FileManager.default.createDirectory(at: holiday, withIntermediateDirectories: true)
        let data = Data((0..<(5 * 1024 * 1024)).map { UInt8($0 % 241) })
        try data.write(to: holiday.appending(path: "1.jpg"))

        let connection = try await connect(FakeFileAgent(desktopURL: guestFolder.url))
        let destinationURL = destination.url.appending(path: "Holiday 2")
        let log = ProgressLog()

        try await GuestFileTransferOperation(.fromGuest(path: holiday.path, destination: destinationURL), connection: connection).run { log.append($0) }

        #expect(try Data(contentsOf: destinationURL.appending(path: "1.jpg")) == data)
        #expect(log.all.last?.completedBytes == UInt64(data.count))
        #expect(log.all.last?.totalBytes == UInt64(data.count))
    }

    @Test func transfersCanBeCancelled() async throws {
        let source = try TemporaryFolder()
        let desktop = try TemporaryFolder()
        let fileURL = source.url.appending(path: "Large.bin")
        try Data(count: 64 * 1024 * 1024).write(to: fileURL)

        let agent = FakeFileAgent(desktopURL: desktop.url)
        agent.acknowledges = false
        let connection = try await connect(agent)
        let operation = GuestFileTransferOperation(.toGuest([fileURL]), connection: connection)

        let task = Task { try await operation.run { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        operation.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func olderAgentsCantCopyFiles() async throws {
        let desktop = try TemporaryFolder()
        let connection = try await connect(FakeFileAgent(desktopURL: desktop.url, protocolVersion: 1))

        #expect(!connection.supportsFileTransfers)
        await #expect(throws: Failure.self) {
            try await GuestFileTransferOperation(.toGuest([desktop.url]), connection: connection).run { _ in }
        }
    }

    @Test func dragsAreCaught() async throws {
        let desktop = try TemporaryFolder()
        let agent = FakeFileAgent(desktopURL: desktop.url)
        agent.dragItems = [GuestDragItem(isFolder: false, path: #"C:\Users\neil\Desktop\Report.pdf"#)]
        let connection = try await connect(agent)

        let items = try await GuestFileTransferOperation.catchDrag(over: connection) { }

        #expect(items == agent.dragItems)
    }

    @MainActor
    @Test func dragsThatArentCaughtInTimeAreEmpty() async throws {
        let desktop = try TemporaryFolder()
        let connection = try await connect(FakeFileAgent(desktopURL: desktop.url))
        let nudges = NudgeCounter()

        let items = try await GuestFileTransferOperation.catchDrag(over: connection, timeout: .milliseconds(400)) { nudges.count += 1 }

        #expect(items.isEmpty)
        #expect(nudges.count > 1)
    }
}

@MainActor
private final class NudgeCounter {
    var count = 0
}
