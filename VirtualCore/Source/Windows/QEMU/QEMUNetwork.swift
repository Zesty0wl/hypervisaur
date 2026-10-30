import Foundation
import OSLog

/// The networks that a Windows virtual machine's network devices are connected to, which the `HypervisaurNetwork` program that
/// comes with Hypervisaur runs while QEMU does.
///
/// QEMU's own user networking gives the guest the Mac's loopback interface at the host's address, and at the other addresses in
/// its network that it doesn't use for something else, so programs in the guest could reach services on the Mac that only accept
/// connections from the Mac itself. QEMU has no option to stop that, but libslirp, which QEMU's user networking is made with,
/// does. `HypervisaurNetwork` runs libslirp with it, and with the same addresses as QEMU's user networking, and QEMU connects
/// each network device to it with a stream network device. The first device's network also serves the shared folders, as
/// QEMU's user networking did. See ``WindowsFolderSharing``.
///
/// Each network listens on its socket in QEMU's runtime directory, and exits once QEMU disconnects from it.
final class QEMUNetwork {
    static let helperName = "HypervisaurNetwork"

    private static let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "QEMUNetwork")

    private let processes: [Process]

    private init(processes: [Process]) {
        self.processes = processes
    }

    /// Starts a network for each of the virtual machine's network devices, and waits until QEMU can connect to them.
    static func start(
        for model: VBVirtualMachine,
        toolchain: QEMUToolchain,
        runtimePaths: QEMULaunchConfiguration.RuntimePaths,
        folderSharing: WindowsFolderSharing?
    ) async throws -> QEMUNetwork {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: helperName) else {
            throw Failure("\(helperName) is missing from Hypervisaur. Install Hypervisaur again.")
        }

        FileManager.default.createFile(atPath: model.networkLogURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: model.networkLogURL)
        defer { try? logHandle.close() }

        var processes = [Process]()
        do {
            for index in model.configuration.hardware.networkDevices.indices {
                var arguments = [toolchain.slirpLibraryURL.path, runtimePaths.networkSocket(forDeviceAt: index).path]
                if index == 0, let folderSharing {
                    arguments += [WindowsFolderSharing.serverAddress, String(WindowsFolderSharing.serverPort), folderSharing.serverCommand]
                }

                let process = Process()
                process.executableURL = helperURL
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = logHandle
                process.terminationHandler = { process in
                    guard process.terminationReason != .exit || process.terminationStatus != 0 else { return }
                    Self.logger.error("The network of device \(index) stopped with status \(process.terminationStatus)")
                }
                try process.run()
                processes.append(process)
            }

            let network = QEMUNetwork(processes: processes)
            try await network.waitUntilListening(at: processes.indices.map(runtimePaths.networkSocket(forDeviceAt:)), logURL: model.networkLogURL)
            return network
        } catch {
            QEMUNetwork(processes: processes).stop()
            throw error
        }
    }

    /// Each network makes its socket once it's listening, so QEMU can connect once they're all there.
    private func waitUntilListening(at socketURLs: [URL], logURL: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while !socketURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            guard processes.allSatisfy(\.isRunning) else {
                throw Failure("The virtual machine’s network failed to start. Check \(logURL.path) for details.")
            }
            guard clock.now < deadline else {
                throw Failure("Timed out waiting for the virtual machine’s network to start.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Stops the networks that are still running. They stop by themselves once QEMU has exited.
    func stop() {
        for process in processes where process.isRunning {
            process.terminate()
        }
    }
}
