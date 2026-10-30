import Foundation
import Testing
@testable import VirtualCore

struct DBusConnectionTests {
    @Test func authenticatesAsTheUserAndAsksToPassFileDescriptors() async throws {
        let (client, server) = try OwnedFileDescriptor.socketPair()
        let connection = DBusConnection(socket: client, name: "Test")

        let peer = Task.detached { try Self.acceptAuthentication(on: server) }
        try await connection.authenticate()

        let userID = Data(String(getuid()).utf8).map { String(format: "%02x", $0) }.joined()
        #expect(try await peer.value == ["AUTH EXTERNAL \(userID)", "NEGOTIATE_UNIX_FD", "BEGIN"])
    }

    @Test func failsToAuthenticateWhenThePeerCantPassFileDescriptors() async throws {
        let (client, server) = try OwnedFileDescriptor.socketPair()
        let connection = DBusConnection(socket: client, name: "Test")

        let peer = Task.detached { try Self.acceptAuthentication(on: server, passesFileDescriptors: false) }

        await #expect(throws: DBusError.self) { try await connection.authenticate() }

        /// The peer waits for the client to begin, until it hangs up.
        connection.close()
        _ = try? await peer.value
    }

    @Test func callsMethodsAndPassesFileDescriptors() async throws {
        let (client, peer) = try await Self.connectedPair { call in
            guard call.member == "Greet", let index = call.body.first?.unixFDIndex else { return .unknownMethod(call) }

            let descriptor = call.fileDescriptors[index].rawValue
            _ = Data("hello".utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            return .reply([.uint32(42)])
        }
        defer { client.close(); peer.close() }

        let pipe = Pipe()
        let reply = try await client.call(
            path: "/test",
            interface: "test.Greeter",
            member: "Greet",
            body: [.unixFD(0)],
            fileDescriptors: [OwnedFileDescriptor(taking: dup(pipe.fileHandleForWriting.fileDescriptor))]
        )

        #expect(reply.body == [.uint32(42)])
        #expect(pipe.fileHandleForReading.readData(ofLength: 5) == Data("hello".utf8))
    }

    @Test func errorRepliesAreThrown() async throws {
        let (client, peer) = try await Self.connectedPair { _ in .invalidArguments("Not like that.") }
        defer { client.close(); peer.close() }

        await #expect(throws: DBusError.remote(name: "org.freedesktop.DBus.Error.InvalidArgs", message: "Not like that.")) {
            try await client.call(path: "/test", interface: "test.Greeter", member: "Greet")
        }
    }

    @Test func methodsThatArentHandledAreUnknown() async throws {
        let (client, peer) = try await Self.connectedPair(handler: nil)
        defer { client.close(); peer.close() }

        do {
            try await client.call(path: "/test", interface: "test.Greeter", member: "Greet")
            Issue.record("The call should have failed.")
        } catch DBusError.remote(let name, _) {
            #expect(name == "org.freedesktop.DBus.Error.UnknownMethod")
        }
    }

    @Test func closingFailsCallsThatAreWaitingForReplies() async throws {
        let (clientSocket, server) = try OwnedFileDescriptor.socketPair()
        let client = DBusConnection(socket: clientSocket, name: "Client")

        let authentication = Task.detached { try Self.acceptAuthentication(on: server) }
        try await client.authenticate()
        _ = try await authentication.value
        client.start { _ in }

        /// Nothing reads the call on the other end, so it's never answered.
        let call = Task { try await client.call(path: "/test", interface: "test.Greeter", member: "Greet") }
        try await Task.sleep(for: .milliseconds(50))
        client.close()

        await #expect(throws: DBusError.connectionClosed) { try await call.value }
        withExtendedLifetime(server) {}
    }

    @Test func reportsWhenThePeerCloses() async throws {
        let (clientSocket, server) = try OwnedFileDescriptor.socketPair()
        let client = DBusConnection(socket: clientSocket, name: "Client")

        let authentication = Task.detached { try Self.acceptAuthentication(on: server) }
        try await client.authenticate()
        _ = try await authentication.value

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.start { _ in continuation.resume() }
            shutdown(server.rawValue, SHUT_RDWR)
        }
    }

    // MARK: - Peer

    /// A connection and its peer, which handles the connection's method calls.
    private static func connectedPair(handler: DBusConnection.MethodHandler?) async throws -> (DBusConnection, DBusConnection) {
        let (clientSocket, peerSocket) = try OwnedFileDescriptor.socketPair()
        let client = DBusConnection(socket: clientSocket, name: "Client")

        let authentication = Task.detached { try acceptAuthentication(on: peerSocket) }
        try await client.authenticate()
        _ = try await authentication.value

        let peer = DBusConnection(socket: peerSocket, name: "Peer")
        peer.start(handlingMethodCallsWith: handler) { _ in }
        client.start { _ in }

        return (client, peer)
    }

    /// Plays the part of a D-Bus server in authentication, and returns the lines that the client sent.
    private static func acceptAuthentication(on socket: OwnedFileDescriptor, passesFileDescriptors: Bool = true) throws -> [String] {
        func readByte() throws -> UInt8 {
            var byte: UInt8 = 0
            guard read(socket.rawValue, &byte, 1) == 1 else { throw DBusError.connectionClosed }
            return byte
        }

        func send(_ line: String) {
            _ = Data((line + "\r\n").utf8).withUnsafeBytes { write(socket.rawValue, $0.baseAddress, $0.count) }
        }

        guard try readByte() == 0 else { throw DBusError.authenticationFailed("The client didn't start with a null byte.") }

        var lines = [String]()
        var line = Data()

        while true {
            line.append(try readByte())
            guard line.suffix(2) == Data("\r\n".utf8) else { continue }

            let text = String(decoding: line.dropLast(2), as: UTF8.self)
            lines.append(text)
            line.removeAll()

            if text.hasPrefix("AUTH EXTERNAL ") {
                send("OK 0123456789abcdef0123456789abcdef")
            } else if text == "NEGOTIATE_UNIX_FD" {
                send(passesFileDescriptors ? "AGREE_UNIX_FD" : "ERROR")
            } else if text == "BEGIN" {
                return lines
            } else {
                send("ERROR")
            }
        }
    }
}
