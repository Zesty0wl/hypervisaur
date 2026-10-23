import Foundation
import ArgumentParser

/// A Model Context Protocol server for coding agents, which talks to them over standard input and output.
///
/// Add it to Claude Code with `claude mcp add hypervisaur -- "/Applications/Hypervisaur.app/Contents/MacOS/vbmcp"`.
struct VBMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vbmcp",
        abstract: "A Model Context Protocol server for creating and running virtual machines in Hypervisaur."
    )

    func run() async throws {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        let server = MCPServer(
            name: "hypervisaur",
            version: version,
            instructions: VirtualMachineTools.instructions,
            tools: VirtualMachineTools.all
        )

        await server.run()
    }
}
