import Foundation
import CryptoKit

/// The virtio drivers that Windows needs for QEMU's virtual devices, such as the network adapter.
///
/// Windows doesn't include drivers for any of the network adapters that QEMU can emulate. Red Hat's virtio drivers are signed
/// by Microsoft and available for ARM, and UTM publishes them on GitHub as part of its guest tools. Only the drivers for
/// Windows 11 on ARM are kept, along with their license. The SPICE agent that shares the clipboard is kept with them, but it
/// comes with the app, since it's built from source; see `WindowsSPICEAgent` in the repository.
public enum WindowsDrivers {
    public static let version = "0.1.271"

    /// Identifies what's kept from the guest tools, so that the drivers are installed again when that changes.
    static let contentsVersion = "\(version)-4"

    /// The folder with the SPICE agent, which shares the clipboard with the Mac, both in the app and with the drivers.
    static let clipboardAgentFolderName = "SPICEAgent"
    static let clipboardAgentFileNames = ["vdagent.exe", "vdservice.exe"]

    static let sourceURL = URL(string: "https://github.com/utmapp/qemu/releases/download/v10.0.2-utm/utm-guest-tools-0.1.271.iso")!
    static let sourceSHA256 = "65b6a69b392ee01dd314c10f3dad9ebbf9c4160be43f5f0dd6bb715944d9095b"

    private static let licenseFileName = "virtio-win_license.txt"
    private static let installedMarkerName = ".installed"

    /// Where the drivers are kept on the host.
    static var directoryURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "Hypervisaur"

        return applicationSupportURL
            .appending(path: bundleID, directoryHint: .isDirectory)
            .appending(path: "WindowsDrivers", directoryHint: .isDirectory)
            .appending(path: contentsVersion, directoryHint: .isDirectory)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directoryURL.appending(path: installedMarkerName).path)
    }

    /// Whether an earlier version of the drivers is installed, which means that Windows virtual machines have been used,
    /// and the drivers should be updated without asking.
    static var isEarlierVersionInstalled: Bool {
        guard !isInstalled else { return false }

        let versions = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.deletingLastPathComponent().path)) ?? []
        return versions.contains { !$0.hasPrefix(".") }
    }

    /// Downloads the guest tools, verifies them, and keeps the drivers for Windows 11 on ARM.
    ///
    /// - Parameter onProgress: Called with the fraction of the download that's complete.
    public static func install(onOutput: @escaping @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        onOutput("Downloading \(sourceURL.absoluteString)")

        let directoryURL = FileManager.default.temporaryDirectory.appending(path: "VirtualBuddyDrivers-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        /// `hdiutil` only recognizes the disc image with its extension.
        let imageURL = directoryURL.appending(path: sourceURL.lastPathComponent)

        try await download(sourceURL, to: imageURL, onProgress: onProgress)

        onOutput("Verifying download")
        try verify(imageURL, sha256: sourceSHA256)

        try await install(fromGuestToolsImageAt: imageURL, onOutput: onOutput)

        onOutput("Windows drivers \(version) installed")
    }

    private static func download(_ url: URL, to destinationURL: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporaryURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let response = response as? HTTPURLResponse, response.statusCode != 200 {
                    continuation.resume(throwing: Failure("Downloading the Windows drivers failed with HTTP status \(response.statusCode)."))
                    return
                }

                guard let temporaryURL else {
                    continuation.resume(throwing: Failure("Downloading the Windows drivers failed."))
                    return
                }

                /// The downloaded file is removed when this returns, so it has to be moved right away.
                do {
                    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                onProgress(progress.fractionCompleted)
            }

            task.resume()
        }
    }

    static func install(fromGuestToolsImageAt imageURL: URL, to destinationURL: URL = directoryURL, onOutput: @escaping @Sendable (String) -> Void) async throws {
        let mountPoint = try await HostDiskImage.mountReadOnly(imageURL)
        defer { HostDiskImage.detach(mountPoint.path) }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let stagingURL = destinationURL.deletingLastPathComponent().appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let drivers = try extractDrivers(from: mountPoint, to: stagingURL)
        onOutput("Found ARM64 drivers: \(drivers.joined(separator: ", "))")

        try copyClipboardAgent(to: stagingURL)
        onOutput("Added the SPICE agent for ARM64")

        FileManager.default.createFile(atPath: stagingURL.appending(path: installedMarkerName).path, contents: Data(contentsVersion.utf8))

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)

        removeOtherVersions(besides: destinationURL)
    }

    private static func removeOtherVersions(besides destinationURL: URL) {
        let parentURL = destinationURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parentURL.path)) ?? []

        for name in names where name != destinationURL.lastPathComponent && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: parentURL.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// The SPICE agent for ARM that comes with the app.
    ///
    /// The agent in UTM's guest tools is built in a way that makes it stop whenever Windows releases the clipboard, which
    /// happens each time something is copied there, and anything copied while it starts again isn't shared with the Mac.
    static var bundledClipboardAgentURL: URL? {
        Bundle.virtualCore.url(forResource: clipboardAgentFolderName, withExtension: nil)
    }

    static func copyClipboardAgent(from sourceURL: URL? = bundledClipboardAgentURL, to destinationURL: URL) throws {
        guard let sourceURL else {
            throw Failure("Hypervisaur doesn’t include the clipboard agent for Windows.")
        }

        for name in clipboardAgentFileNames where !FileManager.default.fileExists(atPath: sourceURL.appending(path: name).path) {
            throw Failure("Hypervisaur doesn’t include \(name), which shares the clipboard with Windows.")
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL.appending(path: clipboardAgentFolderName, directoryHint: .isDirectory))
    }

    /// Where each driver is taken from in the guest tools, if not `w11/ARM64`.
    ///
    /// The Windows 11 build of the display driver doesn't start at the resolution that the virtual machine is configured with.
    /// The Windows Server 2025 build does, and is signed for Windows 11 on ARM too.
    private static let driverSourcePaths = ["viogpudo": "2k25/ARM64"]

    /// Copies `Drivers/<name>/w11/ARM64` from the guest tools into a folder for each driver, returning the names of the drivers.
    static func extractDrivers(from mountPoint: URL, to destinationURL: URL) throws -> [String] {
        let driversURL = mountPoint.appending(path: "Drivers", directoryHint: .isDirectory)
        let driverNames = try FileManager.default.contentsOfDirectory(atPath: driversURL.path).sorted()

        var extracted = [String]()

        for name in driverNames {
            let sourceURL = driversURL.appending(path: name).appending(path: driverSourcePaths[name] ?? "w11/ARM64")
            guard sourceURL.isReadableDirectory else { continue }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL.appending(path: name, directoryHint: .isDirectory))
            extracted.append(name)
        }

        guard extracted.contains("NetKVM") else {
            throw Failure("The Windows drivers don’t include the network driver for ARM.")
        }

        let licenseURL = mountPoint.appending(path: licenseFileName)
        if FileManager.default.fileExists(atPath: licenseURL.path) {
            try FileManager.default.copyItem(at: licenseURL, to: destinationURL.appending(path: licenseFileName))
        }

        return extracted
    }

    static func verify(_ fileURL: URL, sha256 expected: String) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        guard digest == expected else {
            throw Failure("The downloaded Windows drivers don’t match the expected checksum, so they weren’t installed.")
        }
    }
}
