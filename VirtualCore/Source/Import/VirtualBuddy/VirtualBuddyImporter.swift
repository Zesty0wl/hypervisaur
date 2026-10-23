import Foundation
import BuddyFoundation
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "VirtualBuddyImporter")

extension UTType {
    /// Virtual machines created by VirtualBuddy, which Hypervisaur is a fork of.
    static let virtualBuddyBundle = UTType(importedAs: "codes.rambo.VirtualBuddy.VM", conformingTo: .bundle)
}

/// Copies a VirtualBuddy virtual machine into the library. VirtualBuddy's bundles have the same contents,
/// so the copy only needs Hypervisaur's bundle extension. The original is left as it is.
struct VirtualBuddyImporter: VMImporter {
    let appName = "VirtualBuddy"
    let fileType = UTType.virtualBuddyBundle

    @discardableResult
    func importVirtualMachine(from path: FilePath, into library: VMLibraryController) async throws -> VBVirtualMachine {
        let sourceURL = URL(filePath: path.string, directoryHint: .isDirectory)

        let source: VBVirtualMachine
        do {
            source = try VBVirtualMachine(bundleURL: sourceURL, createIfNeeded: false)
        } catch {
            throw Failure("“\(sourceURL.lastPathComponent)” isn’t a VirtualBuddy virtual machine.")
        }

        guard source.qemuProcessIdentifier == nil else {
            throw Failure("“\(source.name)” is running. Shut it down in VirtualBuddy, then import it again.")
        }

        let destinationURL = library.libraryURL
            .appending(path: path.lastComponentWithoutExtension, directoryHint: .isDirectory)
            .appendingPathExtension(VBVirtualMachine.bundleExtension)

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw Failure("You already have a virtual machine named “\(path.lastComponentWithoutExtension)”. If you’d like to import this virtual machine from \(appName), please rename it first.")
        }

        logger.debug("Copying \(sourceURL.path, privacy: .public) to \(destinationURL.path, privacy: .public)")

        /// Copies are clones on APFS, which take no time or space, but a copy to another volume can take a while.
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value

        do {
            let model = try VBVirtualMachine(bundleURL: destinationURL, createIfNeeded: false)

            /// The status of the original virtual machine doesn't apply to the copy.
            for url in [model.qemuPIDFileURL, model.windowsGuestStatusURL] {
                try? FileManager.default.removeItem(at: url)
            }

            return model
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}
