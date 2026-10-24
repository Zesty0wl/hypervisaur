import Foundation
import CryptoKit

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
