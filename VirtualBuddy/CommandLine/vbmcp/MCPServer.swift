import Foundation
import OSLog

/// What a tool returns: text, and optionally an image for the client to look at.
struct MCPToolResult: Sendable {
    struct Image: Sendable {
        var data: Data
        var mimeType: String
    }

    var text: String
    var image: Image?
}

/// A tool that the server offers to MCP clients.
struct MCPTool: Sendable {
    /// Reports progress while a tool runs. The client only receives it if it asked for progress.
    typealias ProgressHandler = @Sendable (_ message: String, _ fraction: Double?) async -> Void
    typealias Run = @Sendable (_ arguments: JSONValue, _ progress: @escaping ProgressHandler) async throws -> MCPToolResult

    var name: String
    var title: String
    var description: String
    var inputSchema: JSONValue
    var run: Run

    init(name: String, title: String, description: String, inputSchema: JSONValue, result run: @escaping Run) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.run = run
    }

    /// A tool that only returns text.
    init(name: String, title: String, description: String, inputSchema: JSONValue, run: @escaping @Sendable (_ arguments: JSONValue, _ progress: @escaping ProgressHandler) async throws -> String) {
        self.init(name: name, title: title, description: description, inputSchema: inputSchema) { arguments, progress in
            MCPToolResult(text: try await run(arguments, progress))
        }
    }
}

/// A Model Context Protocol server that speaks JSON-RPC over standard input and output.
///
/// Each message is a single line of JSON. Standard output carries nothing but messages, so the server logs with OSLog.
actor MCPServer {
    private let name: String
    private let version: String
    private let instructions: String
    private let tools: [String: MCPTool]
    private let toolOrder: [String]

    private let logger = Logger(subsystem: "com.neiljohn.hypervisaur.vbmcp", category: "MCPServer")
    private let output = FileHandle.standardOutput
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private var runningRequests = [JSONValue: Task<Void, Never>]()

    /// The newest protocol version that the server implements, used when the client asks for one it doesn't know.
    private static let latestProtocolVersion = "2025-06-18"
    private static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    init(name: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.toolOrder = tools.map(\.name)
    }

    /// Handles messages until the client closes standard input.
    func run() async {
        for await line in Self.standardInputLines() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            handle(line)
        }

        for task in runningRequests.values {
            task.cancel()
        }
    }

    /// Reads standard input on a thread of its own. Foundation reads all `FileHandle.bytes` sequences on one serial queue,
    /// so waiting for the client's next message that way would stop tools from reading the output of the commands they run.
    private static func standardInputLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.name = "MCPServer.standardInput"
            thread.start()
        }
    }

    // MARK: - Messages

    private struct Message: Decodable {
        var id: JSONValue?
        var method: String?
        var params: JSONValue?
    }

    private func handle(_ line: String) {
        let message: Message
        do {
            message = try JSONDecoder().decode(Message.self, from: Data(line.utf8))
        } catch {
            send(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
            return
        }

        guard let method = message.method else {
            /// A response to a request from the server, which this server never sends.
            return
        }

        guard let id = message.id else {
            handleNotification(method, params: message.params)
            return
        }

        switch method {
        case "initialize":
            respond(to: id, with: initializeResult(for: message.params))
        case "ping":
            respond(to: id, with: [:])
        case "tools/list":
            respond(to: id, with: ["tools": .array(toolOrder.compactMap { tools[$0] }.map(Self.description(of:)))])
        case "tools/call":
            startToolCall(id: id, params: message.params)
        default:
            fail(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleNotification(_ method: String, params: JSONValue?) {
        switch method {
        case "notifications/cancelled":
            guard let requestID = params?["requestId"] else { return }
            runningRequests.removeValue(forKey: requestID)?.cancel()
        default:
            break
        }
    }

    private func initializeResult(for params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let protocolVersion = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.latestProtocolVersion

        return [
            "protocolVersion": .string(protocolVersion),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(name), "version": .string(version)],
            "instructions": .string(instructions),
        ]
    }

    private static func description(of tool: MCPTool) -> JSONValue {
        [
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
        ]
    }

    // MARK: - Tool Calls

    private func startToolCall(id: JSONValue, params: JSONValue?) {
        guard let name = params?["name"]?.stringValue, let tool = tools[name] else {
            fail(id, code: -32602, message: "Unknown tool: \(params?["name"]?.stringValue ?? "none")")
            return
        }

        let arguments = params?["arguments"] ?? [:]
        let progressToken = params?["_meta"]?["progressToken"]

        let task = Task {
            let progress: MCPTool.ProgressHandler = { message, fraction in
                guard let progressToken else { return }
                await self.sendProgress(token: progressToken, message: message, fraction: fraction)
            }

            let result: JSONValue
            do {
                let output = try await tool.run(arguments, progress)
                var content: [JSONValue] = [["type": "text", "text": .string(output.text)]]
                if let image = output.image {
                    content.append(["type": "image", "data": .string(image.data.base64EncodedString()), "mimeType": .string(image.mimeType)])
                }
                result = ["content": .array(content), "isError": false]
            } catch is CancellationError {
                result = ["content": [["type": "text", "text": "Cancelled."]], "isError": true]
            } catch {
                result = ["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true]
            }

            finishToolCall(id: id, result: result)
        }

        runningRequests[id] = task
    }

    private func finishToolCall(id: JSONValue, result: JSONValue) {
        /// Requests that the client cancelled don't get a response.
        guard runningRequests.removeValue(forKey: id) != nil else { return }
        respond(to: id, with: result)
    }

    /// Progress values must increase with every notification. Updates with a fraction are out of a total of 100,
    /// and updates without one move forward by a little.
    private var progressCounters = [JSONValue: Double]()

    private func sendProgress(token: JSONValue, message: String, fraction: Double?) {
        let previous = progressCounters[token] ?? 0
        let progress = max(previous + 0.01, (fraction ?? 0) * 100)
        progressCounters[token] = progress

        var params: [String: JSONValue] = ["progressToken": token, "progress": .number(progress), "message": .string(message)]
        if fraction != nil {
            params["total"] = 100
        }

        send(["jsonrpc": "2.0", "method": "notifications/progress", "params": .object(params)])
    }

    // MARK: - Output

    private func respond(to id: JSONValue, with result: JSONValue) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(_ id: JSONValue, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    private func send(_ message: JSONValue) {
        do {
            var data = try encoder.encode(message)
            data.append(UInt8(ascii: "\n"))
            try output.write(contentsOf: data)
        } catch {
            logger.error("Failed to write message: \(error, privacy: .public)")
        }
    }
}
