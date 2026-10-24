import Foundation
import Darwin
import OSLog

/// The Hypervisaur agent for macOS guests, which runs programs in the guest for the Mac. It's part of the guest app, and its
/// frames travel with the guest app's other messages.
///
/// Programs run with the user's login shell, as the user the guest app runs as, in a session of their own so that stopping one
/// also stops the programs it started, and with a pseudo terminal when they need one.
final class GuestAgentRunner: @unchecked Sendable {
    static let protocolVersion: UInt32 = 1

    /// Output is still read for this long after a program exits, since programs it started in the background can keep its output open.
    static let outputDrainTimeout: TimeInterval = 2

    private let send: @Sendable (Data) -> Void
    private let logger = Logger(subsystem: VirtualWormholeConstants.subsystemName, category: "GuestAgentRunner")
    private let lock = NSLock()
    private var decoder = GuestAgentFrameDecoder()
    private var programs = [UInt32: Program]()

    /// - Parameter send: Sends encoded frames to the Mac, in order.
    init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
    }

    /// Greets the Mac once the guest app is connected to it.
    func connected() {
        sendHello()
    }

    /// Stops everything, since its output can't reach the Mac any more.
    func disconnected() {
        terminateAll()
        lock.withLock { decoder = GuestAgentFrameDecoder() }
    }

    func receive(_ data: Data) {
        let frames: [GuestAgentFrame]
        do {
            frames = try lock.withLock { try decoder.decode(data) }
        } catch {
            logger.error("Invalid frames from the Mac: \(error, privacy: .public)")
            lock.withLock { decoder = GuestAgentFrameDecoder() }
            return
        }

        for frame in frames {
            handle(frame)
        }
    }

    private func handle(_ frame: GuestAgentFrame) {
        switch frame.kind {
        case .reset:
            terminateAll()
            sendHello()
        case .open:
            open(frame)
        case .input:
            program(frame.channel)?.write(frame.payload)
        case .inputEnd:
            program(frame.channel)?.endInput()
        case .resize:
            if let size = frame.terminalSize {
                program(frame.channel)?.resize(columns: size.columns, rows: size.rows)
            }
        case .terminate:
            program(frame.channel)?.terminate()
        case .hello, .output, .errorOutput, .exited, .failed:
            break
        }
    }

    private func program(_ channel: UInt32) -> Program? {
        lock.withLock { programs[channel] }
    }

    private func terminateAll() {
        for program in lock.withLock({ Array(programs.values) }) {
            program.terminate()
        }
    }

    private func sendHello() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let build = sysctlString("kern.osversion") ?? ""

        let info = GuestAgentInfo(
            protocolVersion: Self.protocolVersion,
            system: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(build)) \(machine)"
        )
        send(GuestAgentFrame(.hello, channel: 0, payload: info.payload).encoded())
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private func open(_ frame: GuestAgentFrame) {
        let channel = frame.channel
        do {
            let request = try GuestAgentOpenRequest(payload: frame.payload)
            let program = try Program(request: request) { [weak self] kind, payload in
                self?.send(GuestAgentFrame(kind, channel: channel, payload: payload).encoded())
            } onExit: { [weak self] status in
                guard let self else { return }
                _ = self.lock.withLock { self.programs.removeValue(forKey: channel) }
                self.send(GuestAgentFrame(.exited, channel: channel, payload: GuestAgentFrame.exitStatus(status)).encoded())
            }
            lock.withLock { programs[channel] = program }
            program.start()
        } catch {
            logger.error("Channel \(channel): couldn't start the program: \(error, privacy: .public)")
            send(GuestAgentFrame(.failed, channel: channel, payload: Data(error.localizedDescription.utf8)).encoded())
        }
    }
}

/// A program that the agent runs.
private final class Program: @unchecked Sendable {
    private let processID: pid_t
    private let terminal: Int32?
    private let lock = NSLock()
    private var input: Int32?
    private var readers = [Thread]()
    private let outputs: [(descriptor: Int32, kind: GuestAgentFrame.Kind)]
    private let deliver: @Sendable (GuestAgentFrame.Kind, Data) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(request: GuestAgentOpenRequest, deliver: @escaping @Sendable (GuestAgentFrame.Kind, Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        self.deliver = deliver
        self.onExit = onExit

        let shell = Self.loginShell
        let shellName = (shell as NSString).lastPathComponent
        let arguments = request.command.isEmpty ? ["-\(shellName)"] : ["-\(shellName)", "-c", request.command]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"

        if request.usesTerminal {
            let (processID, terminal) = try Self.spawnInTerminal(path: shell, arguments: arguments, environment: environment, columns: request.columns, rows: request.rows)
            self.processID = processID
            self.terminal = terminal
            input = terminal
            outputs = [(terminal, .output)]
        } else {
            let (processID, input, output, errorOutput) = try Self.spawnWithPipes(path: shell, arguments: arguments, environment: environment)
            self.processID = processID
            self.terminal = nil
            self.input = input
            outputs = [(output, .output), (errorOutput, .errorOutput)]
        }
    }

    func start() {
        for (descriptor, kind) in outputs {
            let thread = Thread { [deliver] in
                var buffer = [UInt8](repeating: 0, count: GuestAgentFrame.preferredChunkSize)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        deliver(kind, Data(buffer[0..<count]))
                    } else if count == 0 || errno != EINTR {
                        break
                    }
                }
            }
            thread.name = "GuestAgentRunner output"
            readers.append(thread)
            thread.start()
        }

        let waiter = Thread { [self] in
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1 && errno == EINTR { }

            waitForOutput()

            let exitStatus: Int32
            if status & 0x7F == 0 {
                exitStatus = (status >> 8) & 0xFF
            } else {
                exitStatus = 128 + (status & 0x7F)
            }

            closeDescriptors()
            onExit(exitStatus)
        }
        waiter.name = "GuestAgentRunner wait"
        waiter.start()
    }

    func write(_ data: Data) {
        guard let input = lock.withLock({ self.input }) else { return }

        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(input, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if errno != EINTR {
                    return
                }
            }
        }
    }

    /// A terminal's input stays open, since closing it would end the terminal.
    func endInput() {
        guard terminal == nil, let input = lock.withLock({ () -> Int32? in defer { self.input = nil }; return self.input }) else { return }
        close(input)
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard let terminal, columns > 0, rows > 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(terminal, TIOCSWINSZ, &size)
    }

    /// Stops the program and everything it started, which are in its session's process group.
    func terminate() {
        kill(-processID, SIGKILL)
    }

    private func waitForOutput() {
        let deadline = Date(timeIntervalSinceNow: GuestAgentRunner.outputDrainTimeout)
        while readers.contains(where: { !$0.isFinished }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func closeDescriptors() {
        let input = lock.withLock { () -> Int32? in defer { self.input = nil }; return self.input }
        if let input, input != terminal {
            close(input)
        }
        for (descriptor, _) in outputs {
            close(descriptor)
        }
    }

    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, shell.pointee != 0 {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func freeCStrings(_ strings: [UnsafeMutablePointer<CChar>?]) {
        strings.forEach { free($0) }
    }

    /// Starts the program in a session of its own, with pipes for its input and output.
    private static func spawnWithPipes(path: String, arguments: [String], environment: [String: String]) throws -> (pid_t, Int32, Int32, Int32) {
        var inputPipe: [Int32] = [0, 0], outputPipe: [Int32] = [0, 0], errorPipe: [Int32] = [0, 0]
        guard pipe(&inputPipe) == 0, pipe(&outputPipe) == 0, pipe(&errorPipe) == 0 else {
            throw GuestAgentError("Couldn’t start the program: \(String(cString: strerror(errno))).")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, NSHomeDirectory())

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = cStrings(arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            freeCStrings(argv)
            freeCStrings(envp)
        }

        var processID: pid_t = 0
        let result = posix_spawn(&processID, path, &actions, &attributes, argv, envp)

        close(inputPipe[0])
        close(outputPipe[1])
        close(errorPipe[1])

        guard result == 0 else {
            [inputPipe[1], outputPipe[0], errorPipe[0]].forEach { close($0) }
            throw GuestAgentError("Couldn’t start the program: \(String(cString: strerror(result))).")
        }
        return (processID, inputPipe[1], outputPipe[0], errorPipe[0])
    }

    /// Starts the program with a pseudo terminal as its controlling terminal. Everything the child needs is prepared before
    /// forking, so that the child only replaces itself with the program.
    private static func spawnInTerminal(path: String, arguments: [String], environment: [String: String], columns: UInt16, rows: UInt16) throws -> (pid_t, Int32) {
        let argv = cStrings(arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        let pathString = strdup(path)
        let directory = strdup(NSHomeDirectory())
        defer {
            freeCStrings(argv)
            freeCStrings(envp)
            free(pathString)
            free(directory)
        }

        var size = winsize(ws_row: rows > 0 ? rows : 24, ws_col: columns > 0 ? columns : 80, ws_xpixel: 0, ws_ypixel: 0)
        var terminal: Int32 = -1
        let processID = forkpty(&terminal, nil, nil, &size)

        if processID == 0 {
            _ = chdir(directory)
            execve(pathString, argv, envp)
            _exit(127)
        }

        guard processID > 0 else {
            throw GuestAgentError("Couldn’t start the program: \(String(cString: strerror(errno))).")
        }

        _ = fcntl(terminal, F_SETFD, FD_CLOEXEC)
        return (processID, terminal)
    }
}
