import Foundation

/// Runs command line tools on the host.
enum HostCommand {
    /// Runs the tool and returns its standard output, throwing with its error output if it fails.
    ///
    /// Output is captured in files rather than pipes because some tools, such as `hdiutil`, hand their work off to helper processes
    /// that inherit the output and keep a pipe open long after the tool itself has exited.
    ///
    /// - Parameter onOutput: Called with each line of standard output as it's produced, which streams the output through a pipe
    /// instead. Only use it for tools that don't leave helper processes behind. Lines may end with a carriage return, which tools
    /// use to update progress in place.
    @discardableResult
    static func run(_ executableURL: URL, _ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "VirtualBuddyCommand-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appending(path: "output")
        let errorURL = directory.appending(path: "error")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = errorHandle

        let outputPipe = onOutput.map { _ in Pipe() }
        process.standardOutput = outputPipe ?? outputHandle

        let streamedOutput: String
        if let outputPipe, let onOutput {
            try process.run()
            streamedOutput = try await stream(outputPipe.fileHandleForReading, to: onOutput)
            await waitUntilExit(process)
        } else {
            try await runUntilExit(process)
            streamedOutput = ""
        }

        guard process.terminationStatus == 0 else {
            let message = ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure("\(executableURL.lastPathComponent) failed with exit code \(process.terminationStatus). \(message)")
        }

        return outputPipe == nil ? ((try? String(contentsOf: outputURL, encoding: .utf8)) ?? "") : streamedOutput
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run(URL(filePath: path), arguments, onOutput: onOutput)
    }

    private static func runUntilExit(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private static func waitUntilExit(_ process: Process) async {
        await Task.detached { process.waitUntilExit() }.value
    }

    private static func stream(_ handle: FileHandle, to onOutput: @Sendable (String) -> Void) async throws -> String {
        var output = Data()
        var line = Data()

        for try await byte in handle.bytes {
            output.append(byte)

            if byte == 0x0A || byte == 0x0D {
                if !line.isEmpty { onOutput(String(decoding: line, as: UTF8.self)) }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }

        if !line.isEmpty { onOutput(String(decoding: line, as: UTF8.self)) }

        return String(decoding: output, as: UTF8.self)
    }
}
