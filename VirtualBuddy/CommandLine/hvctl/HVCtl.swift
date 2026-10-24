import Foundation
import ArgumentParser
import VirtualCore
import VirtualWormhole

/// Runs programs in virtual machines that are running in Hypervisaur, through the Hypervisaur agent in each guest.
///
/// It's a symbolic link to the app, so put `/Applications/Hypervisaur.app/Contents/MacOS` in your `PATH`, or link to it.
struct HVCtl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hvctl",
        abstract: "Runs programs in virtual machines that are running in Hypervisaur.",
        discussion: """
        Commands run in PowerShell on Windows, with /bin/sh on Linux, and with your login shell on macOS. The virtual \
        machine needs the Hypervisaur agent: Windows installs it from its DRIVERS disk, Linux from the HYPERVISAUR disc, \
        and on macOS it's part of the guest app.
        """,
        subcommands: [ExecCommand.self, ShellCommand.self, LogsCommand.self]
    )
}

struct VirtualMachineOption: ParsableArguments {
    @Argument(help: "The name of the virtual machine.")
    var name: String

    func machine() throws -> VBVirtualMachine {
        try VBVirtualMachine.libraryMachine(named: name)
    }
}

extension HVCtl {
    struct ExecCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "exec",
            abstract: "Runs a command in a virtual machine and exits with its status.",
            discussion: "Input that's piped to hvctl is passed to the command."
        )

        @OptionGroup var virtualMachine: VirtualMachineOption

        @Flag(name: .shortAndLong, help: "Runs the command in a terminal, for commands that are interactive.")
        var terminal = false

        @Argument(parsing: .captureForPassthrough, help: "The command to run.")
        var command: [String]

        func run() throws {
            guard !command.isEmpty else {
                throw ValidationError("Give the command to run after the name of the virtual machine.")
            }

            let model = try virtualMachine.machine()
            let status = try TerminalSession.run(
                GuestAgentOpenRequest(command: command.joined(separator: " ")),
                in: model,
                usesTerminal: terminal
            )
            throw ExitCode(status)
        }
    }

    struct ShellCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "shell",
            abstract: "Opens an interactive shell in a virtual machine: PowerShell on Windows, and the login shell elsewhere."
        )

        @OptionGroup var virtualMachine: VirtualMachineOption

        func run() throws {
            let model = try virtualMachine.machine()
            let status = try TerminalSession.run(GuestAgentOpenRequest(command: ""), in: model, usesTerminal: true)
            throw ExitCode(status)
        }
    }

    struct LogsCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Shows a virtual machine's recent log entries, then each new entry as it's logged, until you press Control-C."
        )

        @OptionGroup var virtualMachine: VirtualMachineOption

        func run() throws {
            let model = try virtualMachine.machine()
            let request = GuestAgentOpenRequest(command: GuestLogs.followCommand(for: model.configuration.systemType))
            let status = try TerminalSession.run(request, in: model, usesTerminal: false)
            throw ExitCode(status)
        }
    }
}
