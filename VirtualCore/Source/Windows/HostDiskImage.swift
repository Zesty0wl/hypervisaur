import Foundation
import OSLog

/// Creates and mounts disk images on the host with `hdiutil` and `diskutil`.
enum HostDiskImage {
    private static let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "HostDiskImage")

    /// Creates a sparse raw disk image with a single FAT32 volume, lets `populate` write to the mounted volume, then unmounts it.
    /// The image is removed if anything fails.
    static func createFATDisk(at url: URL, size: Int64, volumeName: String, populate: (URL) async throws -> Void) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        do {
            /// Disk images are sized in whole megabytes.
            let alignedSize = (size + 1024 * 1024 - 1) / (1024 * 1024) * (1024 * 1024)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(alignedSize))
            try handle.close()

            let device = try await attachRaw(url)
            var isDeviceAttached = true
            defer { if isDeviceAttached { detach(device) } }

            try await HostCommand.run("/usr/sbin/diskutil", ["partitionDisk", device, "1", "MBR", "FAT32", volumeName, "100%"])

            let volumeURL = try await mountPoint(of: "\(device)s1")

            /// Keeps Spotlight from adding its index to the disk.
            FileManager.default.createFile(atPath: volumeURL.appending(path: ".metadata_never_index").path, contents: nil)

            try await populate(volumeURL)

            removeMacMetadata(from: volumeURL)

            try await unmount(device)
            detach(device)
            isDeviceAttached = false
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Mounts a disk image read-only at a private location and returns the mount point.
    static func mountReadOnly(_ imageURL: URL) async throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory.appending(path: "VirtualBuddyImage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        do {
            try await HostCommand.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path, imageURL.path])
        } catch {
            try? FileManager.default.removeItem(at: mountPoint)
            throw Failure("Hypervisaur couldn’t open “\(imageURL.lastPathComponent)” as a disc image. \(error.localizedDescription)")
        }

        return mountPoint
    }

    /// Detaches a disk image by its device or mount point, removing private mount points afterwards.
    static func detach(_ deviceOrMountPoint: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["detach", "-force", deviceOrMountPoint]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to detach \(deviceOrMountPoint, privacy: .public): \(error, privacy: .public)")
        }

        if deviceOrMountPoint.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(atPath: deviceOrMountPoint)
        }
    }

    /// Whether an item exists at the path, ignoring case, since disc images may be mounted with a case-sensitive file system
    /// and the case of names differs between them.
    static func itemExists(at components: [String], in directoryURL: URL) -> Bool {
        guard let component = components.first else { return true }

        guard let match = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path))?
            .first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
        else { return false }

        return itemExists(at: Array(components.dropFirst()), in: directoryURL.appending(path: match))
    }

    // MARK: - Attaching

    /// Attaches a raw image as a block device without mounting anything, returning the device path.
    private static func attachRaw(_ imageURL: URL) async throws -> String {
        let output = try await HostCommand.run("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-plist", imageURL.path])

        guard let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let device = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count })
        else {
            throw Failure("Hypervisaur couldn’t attach the disk image \(imageURL.lastPathComponent).")
        }

        return device
    }

    private static func mountPoint(of device: String) async throws -> URL {
        let output = try await HostCommand.run("/usr/sbin/diskutil", ["info", "-plist", device])

        guard let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any],
              let path = plist["MountPoint"] as? String, !path.isEmpty
        else {
            throw Failure("The disk image wasn’t mounted after it was formatted.")
        }

        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Security software commonly scans new volumes and keeps them busy for a moment, so the volume is forcibly unmounted
    /// if it can't be unmounted after a few attempts. Everything has been written by then.
    private static func unmount(_ device: String) async throws {
        try await HostCommand.run("/bin/sync", [])

        for attempt in 1...5 {
            do {
                try await HostCommand.run("/usr/sbin/diskutil", ["unmountDisk", device])
                return
            } catch {
                logger.debug("Unmount attempt \(attempt) failed: \(error, privacy: .public)")
                try await Task.sleep(for: .seconds(1))
            }
        }

        try await HostCommand.run("/usr/sbin/diskutil", ["unmountDisk", "force", device])
    }

    // MARK: - Mac Metadata

    /// macOS stores extended attributes on FAT volumes in hidden `._` files, which Windows has no use for.
    private static func removeMacMetadata(from volumeURL: URL) {
        guard let enumerator = FileManager.default.enumerator(at: volumeURL, includingPropertiesForKeys: nil) else { return }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix("._") {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                removeExtendedAttributes(from: fileURL)
            }
        }
    }

    private static func removeExtendedAttributes(from fileURL: URL) {
        fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }

            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return }

            var names = [CChar](repeating: 0, count: size)
            guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return }

            var start = 0
            for index in 0..<size where names[index] == 0 {
                names.withUnsafeBufferPointer { buffer in
                    _ = removexattr(path, buffer.baseAddress! + start, XATTR_NOFOLLOW)
                }
                start = index + 1
            }
        }
    }
}
