import Foundation

/// A copy of the Windows installer on a FAT32 disk image, which is attached to the virtual machine over NVMe.
///
/// Reading the installer from an emulated USB disc is very slow, and the UEFI firmware can't boot from the faster
/// controllers that disc images could otherwise use. A disk can be attached over NVMe like the boot disk, which both the
/// firmware and Windows Setup support. Booting from a disk also skips the prompt to press a key that the installer shows
/// when it's started from a disc.
public enum WindowsInstallDisk {
    public struct Progress: Sendable {
        public var fractionCompleted: Double
        public var description: String
    }

    static let volumeName = "WININSTALL"

    /// FAT32 can't store files of 4 GiB or larger, so the Windows image is split into parts below that size.
    private static let maximumFileSize: Int64 = 4 * 1024 * 1024 * 1024 - 1
    private static let splitPartSizeInMegabytes = 3800

    /// Creates the installer disk at `url` with the contents of the Windows disc image at `isoURL`.
    ///
    /// - Parameter setup: Settings for installing Windows without interaction, or `nil` to let the user go through Windows Setup.
    public static func create(from isoURL: URL, at url: URL, setup: WindowsUnattendedSetup? = nil, onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        let toolchain = try QEMUToolchain.current()

        guard FileManager.default.isReadableFile(atPath: isoURL.path) else {
            throw Failure("Hypervisaur can’t read the Windows installer at \(isoURL.path).")
        }

        onProgress(Progress(fractionCompleted: 0, description: "Opening Windows Installer"))

        let isoMountPoint = try await HostDiskImage.mountReadOnly(isoURL)
        defer { HostDiskImage.detach(isoMountPoint.path) }

        guard HostDiskImage.itemExists(at: ["efi", "boot", "bootaa64.efi"], in: isoMountPoint) else {
            throw Failure("“\(isoURL.lastPathComponent)” isn’t a Windows installer for ARM. Download the Windows 11 ARM64 disc image from Microsoft and try again.")
        }

        let contents = try installerContents(in: isoMountPoint)

        var image: WindowsInstallImage?
        if setup != nil {
            image = try await preferredImage(in: isoMountPoint, toolchain: toolchain)
        }
        let answerFile = WindowsAnswerFile.xml(setup: setup, image: image)

        try Task.checkCancellation()

        onProgress(Progress(fractionCompleted: 0.02, description: "Creating Installer Disk"))

        /// Leaves room for the file system and the answer file. The image is sparse, so free space doesn't use any storage.
        let size = contents.totalSize + 1024 * 1024 * 1024

        try await HostDiskImage.createFATDisk(at: url, size: size, volumeName: volumeName) { volumeURL in
            try Task.checkCancellation()

            onProgress(Progress(fractionCompleted: 0.05, description: "Copying Windows Installer"))

            var copyArguments = ["-rt"]
            for path in contents.oversizedFiles {
                copyArguments += ["--exclude", "/\(path)"]
            }
            copyArguments += [isoMountPoint.path + "/", volumeURL.path + "/"]
            try await HostCommand.run("/usr/bin/rsync", copyArguments)

            for path in contents.oversizedFiles {
                try Task.checkCancellation()
                try await split(isoMountPoint.appending(path: path), into: volumeURL.appending(path: path), toolchain: toolchain, onProgress: onProgress)
            }

            try Data(answerFile.utf8).write(to: volumeURL.appending(path: "autounattend.xml"))

            onProgress(Progress(fractionCompleted: 0.98, description: "Finishing"))
        }

        onProgress(Progress(fractionCompleted: 1, description: "Windows Installer Ready"))
    }

    // MARK: - Contents

    private struct Contents {
        var totalSize: Int64
        /// Paths relative to the disc's root of the files that have to be split to fit on FAT32.
        var oversizedFiles: [String]
    }

    private static func installerContents(in directoryURL: URL) throws -> Contents {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: keys) else {
            throw Failure("Hypervisaur couldn’t read the contents of the Windows installer.")
        }

        var totalSize: Int64 = 0
        var oversizedFiles = [String]()

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, let size = values.fileSize else { continue }

            totalSize += Int64(size)

            if Int64(size) > maximumFileSize {
                oversizedFiles.append(String(fileURL.standardizedFileURL.path.dropFirst(directoryURL.standardizedFileURL.path.count + 1)))
            }
        }

        for path in oversizedFiles where path.caseInsensitiveCompare("sources/install.wim") != .orderedSame {
            throw Failure("The Windows installer contains a file that’s too large to copy: \(path).")
        }

        return Contents(totalSize: totalSize, oversizedFiles: oversizedFiles)
    }

    /// Splits the Windows image into `install.swm`, `install2.swm` and so on, which Windows Setup reads as a single image.
    private static func split(_ imageURL: URL, into destinationURL: URL, toolchain: QEMUToolchain, onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        let partURL = destinationURL.deletingPathExtension().appendingPathExtension("swm")
        let percentagePattern = /\((\d+)%\)/

        try await HostCommand.run(toolchain.wimlibURL, ["split", imageURL.path, partURL.path, "\(splitPartSizeInMegabytes)"]) { line in
            guard let match = line.firstMatch(of: percentagePattern), let percentage = Double(match.1) else { return }
            onProgress(Progress(fractionCompleted: 0.1 + 0.88 * percentage / 100, description: "Copying Windows Image"))
        }
    }

    // MARK: - Editions

    private static func preferredImage(in isoMountPoint: URL, toolchain: QEMUToolchain) async throws -> WindowsInstallImage {
        let sourcesURL = isoMountPoint.appending(path: "sources", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sourcesURL.path)) ?? []

        guard let imageName = names.first(where: { $0.caseInsensitiveCompare("install.wim") == .orderedSame })
                ?? names.first(where: { $0.caseInsensitiveCompare("install.esd") == .orderedSame })
        else {
            throw Failure("The Windows installer doesn’t contain a Windows image.")
        }

        let images = try await WindowsInstallImage.images(in: sourcesURL.appending(path: imageName), toolchain: toolchain)

        guard let image = WindowsInstallImage.preferred(in: images) else {
            let editions = images.map(\.name).joined(separator: ", ")
            throw Failure("Windows can only be set up automatically from an installer with Windows 11 Pro or Home. This installer has \(editions.isEmpty ? "no editions" : editions).")
        }

        return image
    }
}
