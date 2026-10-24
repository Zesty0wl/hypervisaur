import Foundation
import CryptoKit
import OSLog
import VirtualWormhole

/// The disc that the Hypervisaur agent for Linux is installed from, which is attached to Linux virtual machines until the agent
/// has connected. See `LinuxGuestAgent` in the repository.
enum LinuxGuestTools {
    static let volumeName = "HYPERVISAUR"
    static let resourceFolderName = "LinuxGuestAgent"
    static let fileNames = ["hypervisaur-agent", "hypervisaur-agent.service", "install.sh"]

    private static let connectedMarkerName = "GuestAgent.connected"

    /// Whether the agent has ever connected, which means that it's installed and the disc isn't needed.
    static func hasAgentConnected(in model: VBVirtualMachine) -> Bool {
        FileManager.default.fileExists(atPath: model.metadataFileURL(connectedMarkerName).path)
    }

    static func recordAgentConnected(in model: VBVirtualMachine) {
        let url = model.metadataFileURL(connectedMarkerName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// The protocol version of the agent that comes with the app.
    static var bundledAgentVersion: UInt32? {
        guard let script = try? bundledAgentScript() else { return nil }
        let text = String(decoding: script, as: UTF8.self)
        guard let match = text.firstMatch(of: /(?m)^PROTOCOL_VERSION = (\d+)$/) else { return nil }
        return UInt32(match.1)
    }

    private static func bundledAgentScript() throws -> Data {
        guard let url = Bundle.virtualCore.url(forResource: resourceFolderName, withExtension: nil)?.appending(path: "hypervisaur-agent") else {
            throw Failure("Hypervisaur doesn’t include the agent for Linux.")
        }
        return try Data(contentsOf: url)
    }

    /// A command that replaces the installed agent with the one that comes with the app, and restarts it a moment later,
    /// once the command has finished, since restarting it stops what it's running.
    static func agentUpdateCommand() throws -> String {
        let encoded = try bundledAgentScript().base64EncodedString(options: .lineLength76Characters)
        return """
        set -e
        target=/usr/local/sbin/hypervisaur-agent
        temporary=$(mktemp "$target.XXXXXX")
        trap 'rm -f "$temporary"' EXIT
        base64 -d > "$temporary" <<'HYPERVISAUR_AGENT'
        \(encoded)
        HYPERVISAUR_AGENT
        chmod 0755 "$temporary"
        mv -f "$temporary" "$target"
        trap - EXIT
        systemd-run --quiet --collect --on-active=2 systemctl restart hypervisaur-agent.service
        """
    }

    /// Updates an agent that's older than the one that comes with the app, through the agent itself, so that it doesn't
    /// have to be installed again from the disc. It's only tried once for each connection, in case updating fails.
    static func updateAgentIfNeeded(_ info: GuestAgentInfo, over connection: GuestAgentConnection, guestName: String, attempted: UpdateAttempt) {
        guard let bundledVersion = bundledAgentVersion, info.protocolVersion < bundledVersion, attempted.begin() else { return }

        /// The agent greets the Mac when it starts and again in reply to the Mac's `reset`, which stops whatever it's
        /// running, so the update waits for that to settle rather than being stopped by it.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(3)) {
            guard let current = connection.info, current.protocolVersion < bundledVersion else { return }
            updateAgent(from: current.protocolVersion, to: bundledVersion, over: connection, guestName: guestName)
        }
    }

    private static func updateAgent(from currentVersion: UInt32, to bundledVersion: UInt32, over connection: GuestAgentConnection, guestName: String) {
        let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "LinuxGuestTools")
        logger.notice("Updating the agent in \(guestName, privacy: .public) from protocol \(currentVersion) to \(bundledVersion)")

        do {
            _ = try connection.open(GuestAgentOpenRequest(command: try agentUpdateCommand())) { event in
                switch event {
                case .exited(0):
                    logger.notice("Updated the agent in \(guestName, privacy: .public); it restarts in a moment")
                case .exited(let status):
                    logger.error("Updating the agent in \(guestName, privacy: .public) failed with status \(status)")
                case .failed(let message):
                    logger.error("Updating the agent in \(guestName, privacy: .public) failed: \(message, privacy: .public)")
                case .errorOutput(let data):
                    logger.error("Updating the agent: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                case .output:
                    break
                }
            }
        } catch {
            logger.error("Couldn't update the agent in \(guestName, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Whether an update has been tried, shared by the callbacks of one connection.
    final class UpdateAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var hasBegun = false

        /// Returns `true` the first time only.
        func begin() -> Bool {
            lock.withLock {
                defer { hasBegun = true }
                return !hasBegun
            }
        }
    }

    static func unavailableMessage(for model: VBVirtualMachine) -> String {
        if hasAgentConnected(in: model) {
            return "The Hypervisaur agent isn’t running in “\(model.name)”. In Linux, check it with “systemctl status hypervisaur-agent”."
        } else {
            return "The Hypervisaur agent isn’t installed in “\(model.name)”. To install it from the \(volumeName) disc, run this in a terminal in Linux: sudo mount -o ro /dev/disk/by-label/\(volumeName) /mnt && sudo sh /mnt/install.sh"
        }
    }

    /// The disc, which is made from the files that come with the app the first time it's needed, and again when they change.
    /// It doesn't need to be mounted to be made, unlike a FAT disk.
    static func discImageURL() async throws -> URL {
        guard let sourceURL = Bundle.virtualCore.url(forResource: resourceFolderName, withExtension: nil) else {
            throw Failure("Hypervisaur doesn’t include the agent for Linux.")
        }

        var hasher = SHA256()
        for name in fileNames {
            let data = try Data(contentsOf: sourceURL.appending(path: name))
            hasher.update(data: Data(name.utf8))
            hasher.update(data: data)
        }
        let digest = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()

        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "Hypervisaur", directoryHint: .isDirectory)
            .appending(path: "LinuxGuestTools", directoryHint: .isDirectory)
        let discURL = cacheURL.appending(path: "Hypervisaur-\(digest).iso")

        if FileManager.default.fileExists(atPath: discURL.path) {
            return discURL
        }

        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let stagingURL = FileManager.default.temporaryDirectory.appending(path: "LinuxGuestTools-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        for name in fileNames {
            try FileManager.default.copyItem(at: sourceURL.appending(path: name), to: stagingURL.appending(path: name))
        }

        let temporaryDiscURL = cacheURL.appending(path: ".\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: temporaryDiscURL) }

        try await HostCommand.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", volumeName, "-o", temporaryDiscURL.path, stagingURL.path])

        try FileManager.default.moveItem(at: temporaryDiscURL, to: discURL)

        /// Earlier versions of the disc aren't needed any more.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cacheURL.path)) ?? [] where name.hasSuffix(".iso") && !name.hasPrefix(".") && name != discURL.lastPathComponent {
            try? FileManager.default.removeItem(at: cacheURL.appending(path: name))
        }

        return discURL
    }
}
