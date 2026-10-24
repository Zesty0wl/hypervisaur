import Foundation
import VirtualCore
import OSLog

final class GuestSharedFoldersManager: ObservableObject {

    private lazy var logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: String(describing: Self.self))

    private let queue = DispatchQueue(label: "mount", qos: .userInitiated)

    @Published private(set) var error: Error?

    func mount() async throws {
        logger.notice("Mount shared folders")

        await removeLegacyMountPoint()

        let alreadyMounted = await checkAlreadyMounted()

        guard !alreadyMounted else {
            logger.notice("Shared folders already mounted, skipping mount")
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: Self.defaultMountPointURL.path) {
                logger.info("Shared folders mount point doesn't exist, creating at \(Self.defaultMountPointURL.path, privacy: .public)")

                try FileManager.default.createDirectory(at: Self.defaultMountPointURL, withIntermediateDirectories: true, attributes: nil)
            }

            try await runMount(with: [
                "-t",
                "virtiofs",
                VBSharedFolder.virtualBuddyShareName,
                Self.defaultMountPointURL.path
            ])
        } catch {
            logger.error("Mount shared folders failed with error: \(error, privacy: .public)")

            await MainActor.run {
                self.error = error
            }

            throw error
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(Self.defaultMountPointURL.path, inFileViewerRootedAtPath: Self.defaultMountPointURL.deletingLastPathComponent().path)
    }

    private static let defaultMountPointURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop")
            .appendingPathComponent(VBSharedFolder.guestMountPointName)
    }()

    private static let legacyMountPointURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop")
            .appendingPathComponent(VBSharedFolder.legacyGuestMountPointName)
    }()

    /// `true` if the shared folder is already mounted.
    private func checkAlreadyMounted() async -> Bool {
        await isMounted(at: Self.defaultMountPointURL)
    }

    private func isMounted(at url: URL) async -> Bool {
        guard let mountPoints = (try? await runMount()).flatMap({ $0.components(separatedBy: .newlines) }) else {
            return false
        }

        logger.debug("Mount points: \(mountPoints.joined(separator: "\n"))")

        return mountPoints.contains { $0.contains(" on \(url.path) (") }
    }

    /// Earlier versions of the guest app mounted the shared folders on a folder named after VirtualBuddy. The shared
    /// folders are unmounted from there, and the folder is removed only if it's empty, so nothing in it is lost.
    private func removeLegacyMountPoint() async {
        let url = Self.legacyMountPointURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        if await isMounted(at: url) {
            do {
                try await runCommand("/sbin/umount", arguments: [url.path])
            } catch {
                logger.error("Couldn't unmount shared folders from \(url.path, privacy: .public): \(error, privacy: .public)")
                return
            }
        }

        guard rmdir(url.path) == 0 else {
            logger.notice("Kept \(url.path, privacy: .public), which isn't empty: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        logger.notice("Removed the shared folders mount point used by earlier versions at \(url.path, privacy: .public)")
    }

    @discardableResult
    private func runMount(with arguments: [String] = []) async throws -> String {
        try await runCommand("/sbin/mount", arguments: arguments)
    }

    @discardableResult
    private func runCommand(_ path: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    if proc.terminationStatus == 0 {
                        let output = (try? outPipe.fileHandleForReading.readToEnd()).flatMap({ String(decoding: $0, as: UTF8.self) })
                        continuation.resume(returning: output ?? "")
                    } else {
                        continuation.resume(throwing: CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "\((path as NSString).lastPathComponent) failed with code \(proc.terminationStatus)."]))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}
