import Foundation
import Testing
@testable import VirtualCore
import VirtualWormhole

/// Frames received by the test, which arrive on the transports' threads.
private final class ReceivedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = [GuestAgentFrame]()
    private var disconnections = 0

    func append(_ frame: GuestAgentFrame) { lock.withLock { frames.append(frame) } }
    func disconnected() { lock.withLock { disconnections += 1 } }

    var all: [GuestAgentFrame] { lock.withLock { frames } }
    var disconnectionCount: Int { lock.withLock { disconnections } }
}

struct VirtioSocketGuestAgentTransportTests {
    private func socketPair() throws -> (mac: UnixSocketConnection, guest: UnixSocketConnection) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError.current }
        return (UnixSocketConnection(fileDescriptor: descriptors[0]), UnixSocketConnection(fileDescriptor: descriptors[1]))
    }

    private func readFrame(from socket: UnixSocketConnection) throws -> GuestAgentFrame {
        var decoder = GuestAgentFrameDecoder()
        while true {
            guard let data = try socket.readAvailable(maxLength: 4096) else { throw GuestAgentError("The socket closed.") }
            if let frame = try decoder.decode(data).first { return frame }
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !condition() {
            guard clock.now < deadline else { throw GuestAgentError("Timed out.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func framesMoveToTheSocketAndBackToTheOtherLink() async throws {
        let console = try socketPair()
        let socket = try socketPair()
        let received = ReceivedFrames()

        let transport = VirtioSocketGuestAgentTransport(fallback: GuestAgentStreamTransport(name: "Test console", socket: console.mac))
        transport.start(onFrame: { received.append($0) }, onClose: { _ in })
        defer { transport.close() }

        try transport.send(GuestAgentFrame(.reset, channel: 0))
        #expect(try readFrame(from: console.guest).kind == .reset)

        transport.use(socket.mac) { received.disconnected() }
        #expect(transport.isUsingSocket)

        try transport.send(GuestAgentFrame(.open, channel: 1, payload: GuestAgentOpenRequest(command: "true").payload))
        #expect(try readFrame(from: socket.guest).kind == .open)

        /// While the socket is used, what arrives on the console port is ignored.
        try console.guest.write(GuestAgentFrame(.output, channel: 1, payload: Data("console".utf8)).encoded())
        try socket.guest.write(GuestAgentFrame(.output, channel: 1, payload: Data("socket".utf8)).encoded())
        try await wait { !received.all.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(received.all.map(\.text) == ["socket"])

        socket.guest.close()
        try await wait { received.disconnectionCount == 1 }
        #expect(!transport.isUsingSocket)

        try transport.send(GuestAgentFrame(.reset, channel: 0))
        #expect(try readFrame(from: console.guest).kind == .reset)
    }
}
