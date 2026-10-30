import Foundation
import Testing
@testable import VirtualCore
import VirtualWormhole

struct GuestAgentFrameTests {
    @Test func framesSurviveEncodingAndDecoding() throws {
        let frames = [
            GuestAgentFrame(.reset, channel: 0),
            GuestAgentFrame(.output, channel: 7, payload: Data("hello".utf8)),
            GuestAgentFrame(.exited, channel: 7, payload: GuestAgentFrame.exitStatus(-3)),
        ]

        var decoder = GuestAgentFrameDecoder()
        let decoded = try decoder.decode(frames.reduce(Data()) { $0 + $1.encoded() })

        #expect(decoded == frames)
        #expect(decoded[2].exitStatus == -3)
    }

    @Test func framesAreDecodedOnceTheyArrive() throws {
        let encoded = GuestAgentFrame(.input, channel: 2, payload: Data(repeating: 65, count: 100)).encoded()
        var decoder = GuestAgentFrameDecoder()

        #expect(try decoder.decode(encoded.prefix(5)).isEmpty)
        #expect(try decoder.decode(encoded.dropFirst(5).prefix(50)).isEmpty)
        #expect(try decoder.decode(encoded.dropFirst(55)) == [GuestAgentFrame(.input, channel: 2, payload: Data(repeating: 65, count: 100))])
    }

    @Test func unknownKindsAreSkipped() throws {
        var unknown = GuestAgentFrame(.output, channel: 1, payload: Data("x".utf8)).encoded()
        unknown[4] = 0x7F
        let known = GuestAgentFrame(.output, channel: 1, payload: Data("y".utf8))

        var decoder = GuestAgentFrameDecoder()

        #expect(try decoder.decode(unknown + known.encoded()) == [known])
    }

    @Test func framesSplitAcrossManyReadsDecodeTheSame() throws {
        let frames = (0..<500).map { index in
            GuestAgentFrame(index.isMultiple(of: 3) ? .input : .output, channel: UInt32(index % 7), payload: Data(repeating: UInt8(index % 256), count: index % 97))
        }
        let stream = frames.reduce(Data()) { $0 + $1.encoded() }

        var decoder = GuestAgentFrameDecoder()
        var decoded = [GuestAgentFrame]()
        var offset = stream.startIndex
        var chunkSize = 1
        while offset < stream.endIndex {
            let end = min(offset + chunkSize, stream.endIndex)
            decoded += try decoder.decode(stream[offset..<end])
            offset = end
            chunkSize = chunkSize % 41 + 13
        }

        #expect(decoded == frames)
    }

    /// A guest can send a single batch packed with empty frames, which mustn't take time out of proportion to its size.
    @Test func largeBatchesOfSmallFramesDecodeQuickly() throws {
        var unknown = GuestAgentFrame(.output, channel: 0).encoded()
        unknown[4] = 0xFF
        let batch = Data((0..<500_000).map { _ in unknown }.joined())

        var decoder = GuestAgentFrameDecoder()
        let clock = ContinuousClock()
        let start = clock.now
        let frames = try decoder.decode(batch)
        let elapsed = clock.now - start

        #expect(frames.isEmpty)
        #expect(elapsed < .seconds(2))
    }

    @Test func oversizedFramesAreRejected() {
        let length = UInt32(GuestAgentFrame.maximumPayloadSize + 1)
        let header = Data([UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24), GuestAgentFrame.Kind.output.rawValue, 1, 0, 0, 0])

        var decoder = GuestAgentFrameDecoder()

        #expect(throws: (any Error).self) { try decoder.decode(header) }
    }

    @Test func requestsSurviveEncodingAndDecoding() throws {
        let request = GuestAgentOpenRequest(command: "Get-Date | Out-String", usesTerminal: true, columns: 132, rows: 43)

        #expect(try GuestAgentOpenRequest(payload: request.payload) == request)
    }

    @Test func greetingsSurviveEncodingAndDecoding() throws {
        let info = GuestAgentInfo(protocolVersion: 1, system: "Windows 11 (10.0.26300) ARM64")

        #expect(try GuestAgentInfo(payload: info.payload) == info)
    }
}

struct GuestLogsTests {
    /// zsh, the login shell on macOS, has a built-in `log` command that fails when it's given arguments.
    @Test func macOSLogsArentShownWithTheShellsBuiltInCommand() {
        let commands = [GuestLogs.followCommand(for: .mac), GuestLogs.recentCommand(for: .mac, count: 10)]

        for command in commands {
            let words = command.split(whereSeparator: \.isWhitespace)
            #expect(!words.contains("log"), "\(command)")
            #expect(words.contains("/usr/bin/log"), "\(command)")
        }
    }
}

/// An agent that runs in the test instead of a guest. It greets the host when it's reset, and runs `echo <text>` by replying
/// with the text and exiting with status 0, and anything else by failing.
private final class FakeAgentTransport: GuestAgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable (GuestAgentFrame) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?

    func start(onFrame: @escaping @Sendable (GuestAgentFrame) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            self.onFrame = onFrame
            self.onClose = onClose
        }
    }

    func send(_ frame: GuestAgentFrame) throws {
        let reply = lock.withLock { onFrame }
        guard let reply else { return }

        switch frame.kind {
        case .reset:
            reply(GuestAgentFrame(.hello, channel: 0, payload: GuestAgentInfo(protocolVersion: 1, system: "Test").payload))
        case .open:
            let request = try GuestAgentOpenRequest(payload: frame.payload)
            if request.command.hasPrefix("echo ") {
                reply(GuestAgentFrame(.output, channel: frame.channel, payload: Data(request.command.dropFirst(5).utf8)))
                reply(GuestAgentFrame(.exited, channel: frame.channel, payload: GuestAgentFrame.exitStatus(0)))
            } else {
                reply(GuestAgentFrame(.failed, channel: frame.channel, payload: Data("Unknown command".utf8)))
            }
        default:
            break
        }
    }

    func close() {
        let onClose = lock.withLock { self.onClose }
        onClose?(nil)
    }
}

@Suite(.serialized)
final class GuestAgentServerTests {
    private let bundleURL: URL

    init() {
        bundleURL = FileManager.default.temporaryDirectory.appending(path: "GuestAgentServerTests-\(UUID().uuidString).hypervisaur")
    }

    private func makeServer(connection: GuestAgentConnection) throws -> GuestAgentServer {
        let server = try GuestAgentServer(
            connection: connection,
            socketURL: GuestAgentServer.socketURL(forVirtualMachineAt: bundleURL),
            guestName: "Test"
        ) { "The agent isn’t running." }
        server.start()
        return server
    }

    @Test func socketsAreShortEnoughAndDifferPerVirtualMachine() {
        let url = GuestAgentServer.socketURL(forVirtualMachineAt: bundleURL)
        let other = GuestAgentServer.socketURL(forVirtualMachineAt: bundleURL.deletingLastPathComponent().appending(path: "Other.hypervisaur"))

        #expect(url.path.utf8.count < 104)
        #expect(url != other)
        #expect(url == GuestAgentServer.socketURL(forVirtualMachineAt: bundleURL))
    }

    @Test func commandsRunThroughTheServer() async throws {
        let connection = GuestAgentConnection(transport: FakeAgentTransport(), guestName: "Test")
        connection.start()
        let server = try makeServer(connection: connection)
        defer {
            server.close()
            connection.close()
        }

        let result = try await GuestAgentClient.run("echo hello", inVirtualMachineAt: bundleURL, name: "Test", timeout: .seconds(5))

        #expect(result.output == Data("hello".utf8))
        #expect(result.errorOutput.isEmpty)
        #expect(result.status == 0)
    }

    @Test func failuresAreReportedToTheClient() async throws {
        let connection = GuestAgentConnection(transport: FakeAgentTransport(), guestName: "Test")
        connection.start()
        let server = try makeServer(connection: connection)
        defer {
            server.close()
            connection.close()
        }

        await #expect {
            try await GuestAgentClient.run("reboot", inVirtualMachineAt: bundleURL, name: "Test", timeout: .seconds(5))
        } throws: { error in
            error.localizedDescription == "Unknown command"
        }
    }

    @Test func clientsAreToldWhenTheAgentIsntRunning() async throws {
        let connection = GuestAgentConnection(transport: FakeAgentTransport(), guestName: "Test")
        let server = try makeServer(connection: connection)
        defer {
            server.close()
            connection.close()
        }

        await #expect {
            try await GuestAgentClient.run("echo hello", inVirtualMachineAt: bundleURL, name: "Test", timeout: .seconds(5))
        } throws: { error in
            error.localizedDescription == "The agent isn’t running."
        }
    }

    @Test func virtualMachinesThatArentRunningCantBeReached() async {
        await #expect {
            try await GuestAgentClient.run("echo hello", inVirtualMachineAt: bundleURL, name: "Test", timeout: .seconds(5))
        } throws: { error in
            error.localizedDescription.contains("isn’t running in Hypervisaur")
        }
    }
}
