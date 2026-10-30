import Foundation
import OSLog

/// Locates Homebrew on the host and runs it on behalf of the app.
public struct Homebrew: Sendable {
    public static let installCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    public static let websiteURL = URL(string: "https://brew.sh")!

    /// Homebrew for Apple silicon lives in `/opt/homebrew`. A Homebrew in `/usr/local` on a Mac with Apple silicon is the
    /// one for Intel Macs, which runs with Rosetta and installs a QEMU that can't use the Hypervisor framework for ARM guests.
    private static let candidatePrefixes: [String] = {
        #if arch(arm64)
        ["/opt/homebrew"]
        #else
        ["/usr/local"]
        #endif
    }()

    public let prefix: URL

    public var executableURL: URL { prefix.appending(path: "bin/brew") }

    /// The Homebrew installation on this Mac, or `nil` if Homebrew isn't installed.
    public static var current: Homebrew? {
        for path in candidatePrefixes {
            let prefix = URL(filePath: path, directoryHint: .isDirectory)
            if FileManager.default.isExecutableFile(atPath: prefix.appending(path: "bin/brew").path) {
                return Homebrew(prefix: prefix)
            }
        }
        return nil
    }

    public func binaryURL(named name: String) -> URL {
        prefix.appending(path: "bin").appending(path: name)
    }

    public func libraryURL(named name: String) -> URL {
        prefix.appending(path: "lib").appending(path: name)
    }

    public func sharedResourceURL(_ relativePath: String) -> URL {
        prefix.appending(path: "share").appending(path: relativePath)
    }

    /// The installed versions of the formulae, with a single run of Homebrew. Formulae that aren't installed are left out.
    public func installedVersions(of formulae: [String]) async -> [String: String] {
        /// Homebrew exits with an error when any of the formulae isn't installed, but still lists the ones that are.
        let output = (try? await run(["list", "--formula", "--versions"] + formulae, onOutput: nil, ignoringFailure: true)) ?? ""

        var versions = [String: String]()
        for line in output.split(separator: "\n") {
            let components = line.split(separator: " ")
            guard components.count >= 2, formulae.contains(String(components[0])) else { continue }
            versions[String(components[0])] = String(components[components.count - 1])
        }
        return versions
    }

    /// Installs the formulae, reporting each line of output as it's produced.
    ///
    /// Homebrew normally updates itself before installing, which can take minutes and fail on its own,
    /// so that's skipped. The formulae are installed from the bottles that the existing Homebrew knows about.
    public func install(_ formulae: [String], onOutput: @escaping @Sendable (String) -> Void) async throws {
        try await run(["install"] + formulae, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], onOutput: onOutput)
    }

    @discardableResult
    private func run(_ arguments: [String], environment extraEnvironment: [String: String] = [:], onOutput: (@Sendable (String) -> Void)?, ignoringFailure: Bool = false) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [prefix.appending(path: "bin").path, prefix.appending(path: "sbin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["NONINTERACTIVE"] = "1"
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        var output = ""
        for try await line in pipe.fileHandleForReading.bytes.lines {
            output.append(line)
            output.append("\n")
            onOutput?(line)
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 || ignoringFailure else {
            let lastLines = output.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw Failure("brew \(arguments.joined(separator: " ")) failed with exit code \(process.terminationStatus).\n\(lastLines)")
        }

        return output
    }
}
