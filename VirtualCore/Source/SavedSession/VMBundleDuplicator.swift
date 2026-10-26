import Foundation
import Virtualization

/// Duplicates a virtual machine bundle so that the copy is either complete or doesn't exist.
///
/// The copy is built under a hidden name next to its destination, finished there, and only then moved into place.
/// A saved session is copied along with everything else, so the copy resumes independently from the original.
/// Temporary data from operations that were in progress on the original is never copied, with one exception:
/// a saved session that was interrupted after it was resumed keeps that fact in the copy. The copy's disks may be newer than
/// the session, so resuming the copy has to ask first, exactly like the original.
///
/// On APFS, the copy's files are clones of the original's: they share their storage until either of them changes,
/// so a copy only takes up the space of what's different about it.
struct VMBundleDuplicator: Sendable {
    /// How the copy's guest identifies itself to the network and to the operating system in it.
    enum GuestIdentity: Sendable {
        /// The copy keeps the original's network addresses and machine identifier, which a saved session needs to resume.
        /// The two can't run at the same time.
        case original
        /// The copy gets its own network addresses and, for macOS, its own machine identifier, so that it can run alongside the original.
        case new
    }

    let fileSystem: SavedSessionFileSystem

    init(fileSystem: SavedSessionFileSystem = DefaultSavedSessionFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// - Returns: The copy, with a new library identity, and the guest identity that was asked for.
    func duplicate(bundleAt sourceURL: URL, to destinationURL: URL, guestIdentity: GuestIdentity = .original) throws -> VBVirtualMachine {
        let workURL = destinationURL
            .deletingLastPathComponent()
            .appending(path: ".duplicating-\(UUID().uuidString).\(VBVirtualMachine.bundleExtension)", directoryHint: .isDirectory)

        do {
            /// Operations that were interrupted before the virtual machine could have run are finished (rolled back) on the original first,
            /// so that the copy never starts from files that are halfway through being replaced. What's left is only
            /// the record of a session that was resumed, which the copy has to keep.
            try SavedSessionStorage(bundleURL: sourceURL, fileSystem: fileSystem).recover()

            if guestIdentity == .new {
                try Self.validateNewGuestIdentity(for: try VBVirtualMachine(bundleURL: sourceURL, isNewInstall: false, createIfNeeded: false))
            }

            try fileSystem.copy(from: sourceURL, to: workURL)

            for url in try fileSystem.contentsOfDirectory(at: workURL) {
                let name = url.lastPathComponent
                guard SavedSessionLayout.isTransientName(name), name != SavedSessionLayout.transactionName else { continue }
                try fileSystem.remove(url)
            }

            var copy = try VBVirtualMachine(bundleURL: workURL, isNewInstall: false, createIfNeeded: false)
            copy.metadata.copiedFrom = VBVirtualMachine.Metadata.CopySource(
                uuid: copy.uuid,
                name: sourceURL.deletingPathExtension().lastPathComponent,
                date: .now,
                kind: guestIdentity == .new ? .clone : .duplicate
            )
            copy.uuid = UUID()
            if guestIdentity == .new {
                try copy.generateNewGuestIdentity()
            }
            try copy.saveMetadata()

            copy.bundleURL.creationDate = .now

            try fileSystem.move(from: workURL, to: destinationURL, replacingExisting: false)

            return try VBVirtualMachine(bundleURL: destinationURL, isNewInstall: false, createIfNeeded: false)
        } catch {
            try? fileSystem.remove(workURL)
            throw error
        }
    }

    /// A guest can only be given a new identity when nothing it uses depends on the old one or is shared with the original.
    static func validateNewGuestIdentity(for model: VBVirtualMachine) throws {
        guard model.savedSession == nil else {
            throw Failure("\"\(model.name)\" has a saved session, which can only resume with the identity it was saved with. Resume it and shut it down before cloning it, or duplicate it instead.")
        }

        let sharedImages = ExternalDiskImageCopier.externalDevices(of: model).filter { $0.isEnabled && !$0.isReadOnly }
        guard sharedImages.isEmpty else {
            let names = sharedImages.compactMap { device -> String? in
                guard case .customImage(let url) = device.backing else { return nil }
                return url.lastPathComponent
            }
            throw Failure("\"\(model.name)\" uses disk images from outside of its bundle that a clone would write to at the same time as the original: \(names.joined(separator: ", ")). Remove them or make them read-only before cloning it.")
        }
    }
}

private extension VBVirtualMachine {
    /// Gives the guest new network addresses and, for macOS, a new machine identifier, which is what the guest sees as its serial number.
    mutating func generateNewGuestIdentity() throws {
        for index in configuration.hardware.networkDevices.indices {
            configuration.hardware.networkDevices[index].macAddress = VZMACAddress.randomLocallyAdministered().string.uppercased()
        }

        if FileManager.default.fileExists(atPath: machineIdentifierURL.path) {
            try generateNewMachineIdentifier()
        }
    }
}
