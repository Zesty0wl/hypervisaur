import Foundation
import Darwin
import VirtualCore
import VirtualWormhole

/// Connects the terminal that `hvctl` runs in to a program in a guest, until the program exits.
enum TerminalSession {
    /// Returns the program's exit status.
    static func run(_ request: GuestAgentOpenRequest, in model: VBVirtualMachine, usesTerminal: Bool) throws -> Int32 {
        let client = try GuestAgentClient(virtualMachineAt: model.bundleURL, name: model.name)

        let inputIsTerminal = isatty(STDIN_FILENO) != 0
        var request = request
        request.usesTerminal = usesTerminal
        if usesTerminal, let size = terminalSize() {
            request.columns = size.columns
            request.rows = size.rows
        }
        try client.open(request)

        /// In a terminal of its own, the program handles every key itself, including Control-C.
        let rawMode = usesTerminal && inputIsTerminal ? try RawTerminalMode() : nil
        defer { rawMode?.restore() }

        var signalSources = [DispatchSourceSignal]()
        defer { signalSources.forEach { $0.cancel() } }

        if usesTerminal {
            signalSources.append(handleSignal(SIGWINCH) {
                guard let size = terminalSize() else { return }
                try? client.resize(columns: size.columns, rows: size.rows)
            })
        } else {
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                signalSources.append(handleSignal(signalNumber) {
                    try? client.terminate()
                })
            }
        }

        /// Input typed in a terminal isn't waited for, unless the program is interactive.
        if usesTerminal || !inputIsTerminal {
            forwardInput(to: client, endsInput: !usesTerminal)
        } else {
            try client.endInput()
        }

        while let event = try client.nextEvent() {
            switch event {
            case .output(let data):
                FileHandle.standardOutput.write(data)
            case .errorOutput(let data):
                FileHandle.standardError.write(data)
            case .exited(let status):
                return status
            case .failed(let message):
                throw Failure(message)
            }
        }

        throw Failure("The connection to “\(model.name)” was lost.")
    }

    private static func forwardInput(to client: GuestAgentClient, endsInput: Bool) {
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    guard (try? client.send(input: Data(buffer[0..<count]))) != nil else { return }
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            if endsInput {
                try? client.endInput()
            }
        }
        thread.name = "hvctl input"
        thread.start()
    }

    private static func handleSignal(_ signalNumber: Int32, handler: @escaping () -> Void) -> DispatchSourceSignal {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    private static func terminalSize() -> (columns: UInt16, rows: UInt16)? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return (size.ws_col, size.ws_row)
    }
}

/// Passes each key straight to the program in the guest, until it's restored.
private final class RawTerminalMode {
    private var original = termios()
    private var isRestored = false

    init() throws {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw Failure("hvctl couldn’t set up the terminal.")
        }

        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw Failure("hvctl couldn’t set up the terminal.")
        }
    }

    func restore() {
        guard !isRestored else { return }
        isRestored = true
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }

    deinit {
        restore()
    }
}
