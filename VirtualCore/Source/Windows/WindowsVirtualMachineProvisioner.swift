import Foundation

/// Creates a Windows virtual machine that's ready to install Windows when it first starts, without going through the
/// installation wizard. Used by automation, which then starts the virtual machine in the app.
public enum WindowsVirtualMachineProvisioner {
    public struct Request: Sendable {
        public var name: String
        /// The Windows 11 for ARM disc image to install from.
        public var installerURL: URL
        /// Settings for installing Windows without interaction, or `nil` to go through Windows Setup in the virtual machine.
        public var setup: WindowsUnattendedSetup?
        public var diskSize: UInt64
        public var memorySize: UInt64
        public var cpuCount: Int

        public init(
            name: String,
            installerURL: URL,
            setup: WindowsUnattendedSetup?,
            diskSize: UInt64 = VBManagedDiskImage.defaultWindowsBootDiskImageSize,
            memorySize: UInt64 = VBMacDevice.defaultWindows.memorySize,
            cpuCount: Int = VBMacDevice.defaultWindows.cpuCount
        ) {
            self.name = name
            self.installerURL = installerURL
            self.setup = setup
            self.diskSize = diskSize
            self.memorySize = memorySize
            self.cpuCount = cpuCount
        }
    }

    /// Windows 11 requires 64 GB of storage.
    public static let minimumDiskSize: UInt64 = 64 * .storageGigabyte

    /// Checks the request, creates the virtual machine in the library and prepares its installer disk.
    /// Nothing is left in the library if this fails.
    public static func create(
        _ request: Request,
        in libraryURL: URL,
        onProgress: @escaping @Sendable (WindowsInstallDisk.Progress) -> Void
    ) async throws -> VBVirtualMachine {
        try validateName(request.name)

        let bundleURL = libraryURL
            .appending(path: request.name, directoryHint: .isDirectory)
            .appendingPathExtension(VBVirtualMachine.bundleExtension)

        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw Failure("There’s already a virtual machine named “\(request.name)”.")
        }

        try validate(request)

        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)

        do {
            var model = try VBVirtualMachine(creatingWindowsMachineAt: bundleURL)

            model.configuration.hardware.memorySize = request.memorySize
            model.configuration.hardware.cpuCount = request.cpuCount
            if let index = model.configuration.hardware.storageDevices.firstIndex(where: \.isBootVolume),
               case .managedImage(var image) = model.configuration.hardware.storageDevices[index].backing {
                image.size = request.diskSize
                model.configuration.hardware.storageDevices[index].backing = .managedImage(image)
            }
            model.metadata.updateInstallImageURL(request.installerURL)

            if let error = model.configuration.qemuSupportState.errors.first {
                throw Failure(error)
            }

            try model.saveMetadata()

            if let setup = request.setup {
                try model.saveWindowsUnattendedSetup(setup)
            }

            try await WindowsInstallDisk.create(from: request.installerURL, at: model.windowsInstallDiskURL, setup: request.setup, onProgress: onProgress)

            return model
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
    }

    public static func validate(_ request: Request) throws {
        try validateName(request.name)

        if let setup = request.setup {
            try WindowsUnattendedSetup.validateAccountName(setup.accountName)
        }

        guard FileManager.default.isReadableFile(atPath: request.installerURL.path) else {
            throw Failure("There’s no Windows installer at \(request.installerURL.path).")
        }

        guard request.diskSize >= minimumDiskSize else {
            throw Failure("Windows 11 needs a disk of at least \(minimumDiskSize / .storageGigabyte) GB.")
        }

        let memoryRange = UInt64(VBMacDevice.minimumWindowsMemorySize)...(UInt64(VBMacDevice.maximumMemorySizeInGigabytes) * .storageGigabyte)
        guard memoryRange.contains(request.memorySize) else {
            throw Failure("Windows virtual machines can have between \(memoryRange.lowerBound / .storageGigabyte) and \(memoryRange.upperBound / .storageGigabyte) GB of memory on this Mac.")
        }

        guard VBMacDevice.virtualCPUCountRange.contains(request.cpuCount) else {
            throw Failure("Windows virtual machines can have between \(VBMacDevice.virtualCPUCountRange.lowerBound) and \(VBMacDevice.virtualCPUCountRange.upperBound) processor cores on this Mac.")
        }

        _ = try QEMUToolchain.current()

        guard WindowsDrivers.isInstalled else {
            throw Failure("The Windows drivers haven’t been downloaded yet. Install the missing Windows components first.")
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure("Enter a name for the virtual machine.")
        }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw Failure("Virtual machine names can’t contain “/” or “:”, or start with a period.")
        }
    }
}
