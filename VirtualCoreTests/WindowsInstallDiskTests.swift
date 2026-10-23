import Foundation
import CryptoKit
import Testing
@testable import VirtualCore

@Suite(.enabled(if: (try? QEMUToolchain.current()) != nil), .serialized)
struct WindowsInstallDiskTests {
    @Test func installerFilesAndAnswerFileAreCopiedToDisk() async throws {
        let directory = try makeTemporaryDirectory()
        let isoURL = try makeDiscImage(in: directory, files: [
            "efi/boot/bootaa64.efi": Data("boot".utf8),
            "sources/boot.wim": Data(count: 4096),
            "sources/install.wim": Data(count: 8192),
            "setup.exe": Data("setup".utf8),
        ])
        let diskURL = directory.appending(path: "Installer.img")

        try await WindowsInstallDisk.create(from: isoURL, at: diskURL) { _ in }

        let mountPoint = try mount(diskURL, in: directory)
        defer { detach(mountPoint) }

        for path in ["efi/boot/bootaa64.efi", "sources/boot.wim", "sources/install.wim", "setup.exe", "autounattend.xml"] {
            #expect(FileManager.default.fileExists(atPath: mountPoint.appending(path: path).path), "\(path) is missing")
        }

        let answerFile = try String(contentsOf: mountPoint.appending(path: "autounattend.xml"), encoding: .utf8)
        #expect(answerFile.contains("BypassSecureBootCheck"))

        let leftovers = FileManager.default.enumerator(atPath: mountPoint.path)?.compactMap { $0 as? String }.filter { ($0 as NSString).lastPathComponent.hasPrefix("._") } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func installerForOtherArchitecturesIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        let isoURL = try makeDiscImage(in: directory, files: [
            "efi/boot/bootx64.efi": Data("boot".utf8),
            "sources/install.wim": Data(count: 4096),
        ])
        let diskURL = directory.appending(path: "Installer.img")

        await #expect(throws: (any Error).self) {
            try await WindowsInstallDisk.create(from: isoURL, at: diskURL) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: diskURL.path))
    }

    @Test func onlyWindows11ARMDriversAreExtracted() throws {
        let directory = try makeTemporaryDirectory()
        let toolsURL = directory.appending(path: "tools", directoryHint: .isDirectory)
        for path in ["Drivers/NetKVM/w11/ARM64/netkvm.inf", "Drivers/NetKVM/w11/amd64/netkvm.inf", "Drivers/NetKVM/w10/ARM64/netkvm.inf", "Drivers/viostor/w11/ARM64/viostor.inf", "Drivers/viogpudo/w11/ARM64/viogpudo.inf", "Drivers/viogpudo/2k25/ARM64/viogpudo.inf", "Drivers/qxl/w10/amd64/qxl.inf", "virtio-win_license.txt"] {
            let fileURL = toolsURL.appending(path: path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: fileURL)
        }
        let destinationURL = directory.appending(path: "drivers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let extracted = try WindowsDrivers.extractDrivers(from: toolsURL, to: destinationURL)

        #expect(extracted == ["NetKVM", "viogpudo", "viostor"])
        let netkvm = try String(contentsOf: destinationURL.appending(path: "NetKVM/netkvm.inf"), encoding: .utf8)
        #expect(netkvm == "Drivers/NetKVM/w11/ARM64/netkvm.inf")
        let viogpudo = try String(contentsOf: destinationURL.appending(path: "viogpudo/viogpudo.inf"), encoding: .utf8)
        #expect(viogpudo == "Drivers/viogpudo/2k25/ARM64/viogpudo.inf")
        #expect(FileManager.default.fileExists(atPath: destinationURL.appending(path: "virtio-win_license.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destinationURL.appending(path: "qxl").path))
    }

    @Test(.enabled(if: isSevenZipInstalled))
    func driversAreInstalledFromGuestToolsDiscImage() async throws {
        let directory = try makeTemporaryDirectory()
        let isoURL = try makeDiscImage(in: directory, files: [
            "Drivers/NetKVM/w11/ARM64/netkvm.inf": Data("netkvm".utf8),
            "Drivers/NetKVM/w11/ARM64/netkvmco.dll": Data("co".utf8),
            "Drivers/NetKVM/w11/amd64/netkvm.inf": Data("x64".utf8),
            "virtio-win_license.txt": Data("license".utf8),
            "utm-guest-tools-0.1.271.exe": try makeGuestToolsInstaller(in: directory),
        ])
        let destinationURL = directory.appending(path: "WindowsDrivers/0.1.271-3", directoryHint: .isDirectory)
        let earlierVersionURL = directory.appending(path: "WindowsDrivers/0.1.271-2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: earlierVersionURL, withIntermediateDirectories: true)

        try await WindowsDrivers.install(fromGuestToolsImageAt: isoURL, to: destinationURL) { _ in }

        #expect(FileManager.default.fileExists(atPath: destinationURL.appending(path: "NetKVM/netkvm.inf").path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.appending(path: "NetKVM/netkvmco.dll").path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.appending(path: "virtio-win_license.txt").path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.appending(path: ".installed").path))
        #expect(try Data(contentsOf: destinationURL.appending(path: "SPICEAgent/vdagent.exe")) == Data("agent".utf8))
        #expect(try Data(contentsOf: destinationURL.appending(path: "SPICEAgent/vdservice.exe")) == Data("service".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destinationURL.deletingLastPathComponent().path)
        #expect(leftovers == ["0.1.271-3"])
    }

    @Test func guestToolsWithoutTheInstallerAreRejected() async throws {
        let directory = try makeTemporaryDirectory()

        await #expect(throws: (any Error).self) {
            try await WindowsDrivers.extractClipboardAgent(from: directory, to: directory)
        }
    }

    @Test func driversWithoutNetworkDriverAreRejected() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appending(path: "tools/Drivers/viostor/w11/ARM64/viostor.inf")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("viostor".utf8).write(to: fileURL)

        #expect(throws: (any Error).self) {
            try WindowsDrivers.extractDrivers(from: directory.appending(path: "tools"), to: directory)
        }
    }

    @Test func downloadWithWrongChecksumIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appending(path: "download.iso")
        try Data("not the guest tools".utf8).write(to: fileURL)

        #expect(throws: (any Error).self) {
            try WindowsDrivers.verify(fileURL, sha256: WindowsDrivers.sourceSHA256)
        }
        try WindowsDrivers.verify(fileURL, sha256: sha256(of: fileURL))
    }

    @Test func driversDiskContainsDriversFolder() async throws {
        let directory = try makeTemporaryDirectory()
        let driversURL = directory.appending(path: "drivers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: driversURL.appending(path: "NetKVM"), withIntermediateDirectories: true)
        try Data("inf".utf8).write(to: driversURL.appending(path: "NetKVM/netkvm.inf"))
        try Data("0.1.271".utf8).write(to: driversURL.appending(path: ".installed"))
        let diskURL = directory.appending(path: "Drivers.img")

        try await WindowsDriversDisk.create(at: diskURL, from: driversURL)

        let mountPoint = try mount(diskURL, in: directory)
        defer { detach(mountPoint) }

        let folderURL = mountPoint.appending(path: WindowsDriversDisk.driversFolderName)
        #expect(FileManager.default.fileExists(atPath: folderURL.appending(path: "NetKVM/netkvm.inf").path))
        #expect(!FileManager.default.fileExists(atPath: folderURL.appending(path: ".installed").path))
        let script = try String(contentsOf: folderURL.appending(path: WindowsDriversDisk.setupScriptName), encoding: .utf8)
        #expect(script == WindowsDriversDisk.setupScript)
        let statusScript = try String(contentsOf: folderURL.appending(path: WindowsDriversDisk.statusScriptName), encoding: .utf8)
        #expect(statusScript == WindowsDriversDisk.statusScript)
        let setupVersion = try String(contentsOf: folderURL.appending(path: WindowsDriversDisk.setupVersionFileName), encoding: .utf8)
        #expect(setupVersion == WindowsDriversDisk.contentsVersion)
    }

    @Test func setupScriptInstallsTheClipboardAgentService() {
        let script = WindowsDriversDisk.setupScript
        #expect(script.contains("copy /y \"%~dp0SPICEAgent\\*.exe\" \"%AgentFolder%\""))
        #expect(script.contains("\"%AgentFolder%\\vdservice.exe\" install"))
        #expect(script.contains("net start vdservice"))
        #expect(script.contains("copy /y \"%~dp0Setup.version\" \"%ProgramData%\\Hypervisaur\\Setup.version\""))
    }

    @Test func statusScriptRunsNewerSetupWhenWindowsStarts() {
        let script = WindowsDriversDisk.statusScript
        #expect(script.contains("fc /b \"%%d:\\VirtIODrivers\\Setup.version\" \"%ProgramData%\\Hypervisaur\\Setup.version\" >nul 2>&1 || call \"%%d:\\VirtIODrivers\\Setup.cmd\""))
    }

    @Test func setupScriptInstallsDriversAndSignInTask() {
        let script = WindowsDriversDisk.setupScript
        #expect(script.contains("pnputil /add-driver \"%~dp0*.inf\" /subdirs /install"))
        #expect(script.contains("schtasks /create /f /tn \"Hypervisaur\\Started\" /sc onstart /ru SYSTEM /tr \"%StatusScript% startup\""))
        #expect(script.contains("schtasks /create /f /tn \"Hypervisaur\\Signed In\" /sc onlogon /ru SYSTEM /tr \"%StatusScript%\""))
        #expect(!script.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func statusScriptReportsStartupAndSignInAfterSetup() {
        let script = WindowsDriversDisk.statusScript
        #expect(script.contains("echo started>\\\\.\\Global\\hypervisaur.status"))
        #expect(script.contains("echo signed-in>\\\\.\\Global\\hypervisaur.status"))
        #expect(script.contains("IMAGE_STATE_COMPLETE"))
        #expect(script.contains("find /i /v \"defaultuser\""))
        #expect(!script.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func answerFileRunsSetupScriptFromDriversDisk() {
        let scriptPath = "%d:\\\(WindowsDriversDisk.driversFolderName)\\\(WindowsDriversDisk.setupScriptName)"
        #expect(WindowsAnswerFile.xml().contains("@if exist \(scriptPath) call \(scriptPath)"))
    }

    // MARK: - Helpers

    private func sha256(of fileURL: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: fileURL)).map { String(format: "%02x", $0) }.joined()
    }

    private static var isSevenZipInstalled: Bool {
        guard let brew = Homebrew.current else { return false }
        return FileManager.default.isExecutableFile(atPath: QEMUToolchain(homebrew: brew).sevenZipURL.path)
    }

    /// The SPICE agent is unpacked from the guest tools installer with 7-Zip, which reads a zip archive just as well.
    private func makeGuestToolsInstaller(in directory: URL) throws -> Data {
        let agentURL = directory.appending(path: "installer/ARM64", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agentURL, withIntermediateDirectories: true)
        try Data("agent".utf8).write(to: agentURL.appending(path: "vdagent.exe"))
        try Data("service".utf8).write(to: agentURL.appending(path: "vdservice.exe"))
        try Data("x64".utf8).write(to: directory.appending(path: "installer/vdagent.exe"))

        let archiveURL = directory.appending(path: "installer.zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", agentURL.path, archiveURL.path])
        return try Data(contentsOf: archiveURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WindowsInstallDiskTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDiscImage(in directory: URL, files: [String: Data]) throws -> URL {
        let stagingURL = directory.appending(path: "staging", directoryHint: .isDirectory)
        for (path, contents) in files {
            let fileURL = stagingURL.appending(path: path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL)
        }

        let isoURL = directory.appending(path: "Windows.iso")
        try runTool("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-udf", "-o", isoURL.path, stagingURL.path])
        return isoURL
    }

    private func mount(_ diskURL: URL, in directory: URL) throws -> URL {
        let mountPoint = directory.appending(path: "mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try runTool("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-readonly", "-nobrowse", "-mountpoint", mountPoint.path, diskURL.path])
        return mountPoint
    }

    private func detach(_ mountPoint: URL) {
        try? runTool("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("\(path) \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus)")
        }
    }
}
