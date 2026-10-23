import Foundation
import OSLog

/// Client for the QEMU Machine Protocol, used to control a running QEMU process.
final class QMPClient: @unchecked Sendable {
    struct Event: Sendable {
        var name: String
        var data: [String: String]
    }

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "QMPClient")

    private let connection: UnixSocketConnection
    private let lock = NSLock()
    private var nextCommandID = 0
    private var pendingCommands = [String: CheckedContinuation<Any?, Error>]()
    private var isClosed = false

    private let onEvent: @Sendable (Event) -> Void

    private init(connection: UnixSocketConnection, onEvent: @escaping @Sendable (Event) -> Void) {
        self.connection = connection
        self.onEvent = onEvent
    }

    /// Connects to QEMU's monitor socket and negotiates capabilities.
    static func connect(path: String, timeout: Duration, onEvent: @escaping @Sendable (Event) -> Void) async throws -> QMPClient {
        let connection = try await UnixSocketConnection.connect(path: path, timeout: timeout)
        let client = QMPClient(connection: connection, onEvent: onEvent)

        let greeting = try await client.readGreeting()
        client.logger.debug("Connected to QMP: \(greeting, privacy: .public)")

        client.startReading()

        try await client.execute("qmp_capabilities")

        return client
    }

    @discardableResult
    func execute(_ command: String, arguments: [String: Any]? = nil) async throws -> Any? {
        let id: String = lock.withLock {
            nextCommandID += 1
            return "vb-\(nextCommandID)"
        }

        var message: [String: Any] = ["execute": command, "id": id]
        if let arguments { message["arguments"] = arguments }

        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let registered: Bool = lock.withLock {
                guard !isClosed else { return false }
                pendingCommands[id] = continuation
                return true
            }

            guard registered else {
                continuation.resume(throwing: Failure("The connection to QEMU has been closed."))
                return
            }

            do {
                try connection.write(data)
            } catch {
                let pending = lock.withLock { pendingCommands.removeValue(forKey: id) }
                pending?.resume(throwing: error)
            }
        }
    }

    func close() {
        connection.close()
        failPendingCommands(with: Failure("The connection to QEMU has been closed."))
    }

    // MARK: - Reading

    private var lineBuffer = Data()

    private func readLine() throws -> Data {
        while true {
            if let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer[lineBuffer.startIndex..<newline]
                lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
                return Data(line)
            }
            lineBuffer.append(try connection.readByte())
        }
    }

    private func readGreeting() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [self] in
                do {
                    let line = try readLine()
                    continuation.resume(returning: String(decoding: line, as: UTF8.self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startReading() {
        let thread = Thread { [self] in
            while true {
                let line: Data
                do {
                    line = try readLine()
                } catch {
                    failPendingCommands(with: error)
                    return
                }

                handle(line)
            }
        }
        thread.name = "QMPClient"
        thread.start()
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty else { return }

        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            logger.warning("Ignoring malformed QMP message")
            return
        }

        if let event = message["event"] as? String {
            let data = (message["data"] as? [String: Any]) ?? [:]
            onEvent(Event(name: event, data: data.mapValues { "\($0)" }))
            return
        }

        guard let id = message["id"] as? String else { return }

        let continuation = lock.withLock { pendingCommands.removeValue(forKey: id) }

        if let error = message["error"] as? [String: Any] {
            let description = error["desc"] as? String ?? "Unknown error"
            continuation?.resume(throwing: Failure("QEMU: \(description)"))
        } else {
            continuation?.resume(returning: message["return"])
        }
    }

    private func failPendingCommands(with error: Error) {
        let pending: [CheckedContinuation<Any?, Error>] = lock.withLock {
            isClosed = true
            defer { pendingCommands.removeAll() }
            return Array(pendingCommands.values)
        }

        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }
}
