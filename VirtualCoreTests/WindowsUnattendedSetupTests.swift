import Foundation
import Testing
@testable import VirtualCore

struct WindowsUnattendedSetupTests {
    // MARK: - Account Names

    @Test(arguments: ["neiljohn", "Neil Johnson", "dev.user", "a", String(repeating: "x", count: 20)])
    func validAccountNamesAreAccepted(name: String) throws {
        try WindowsUnattendedSetup.validateAccountName(name)
    }

    @Test(arguments: ["", "bad@name", "back\\slash", "a:b", String(repeating: "x", count: 21), "...", "Administrator", "guest"])
    func invalidAccountNamesAreRejected(name: String) {
        #expect(throws: (any Error).self) { try WindowsUnattendedSetup.validateAccountName(name) }
    }

    @Test func emptyPasswordMeansNoPassword() {
        #expect(WindowsUnattendedSetup(accountName: "neiljohn", password: "").password == nil)
        #expect(WindowsUnattendedSetup(accountName: "neiljohn", password: " secret ").password == " secret ")
    }

    // MARK: - Time Zones

    @Test func timeZonesAreMappedToWindowsNames() {
        #expect(WindowsTimeZone.name(forIdentifier: "Europe/London") == "GMT Standard Time")
        #expect(WindowsTimeZone.name(forIdentifier: "America/Los_Angeles") == "Pacific Standard Time")
        #expect(WindowsTimeZone.name(forIdentifier: "Not/AZone") == nil)
    }

    // MARK: - Editions

    private static let wimInfo = """
    WIM Information:
    ----------------
    Path:           /Volumes/CCCOMA/sources/install.wim
    Image Count:    3

    Available Images:
    -----------------
    Index:                  1
    Name:                   Windows 11 Home
    Architecture:           ARM64
    Edition ID:             Core
    Languages:              en-GB
    Default Language:       en-GB

    Index:                  2
    Name:                   Windows 11 Home Single Language
    Edition ID:             CoreSingleLanguage
    Default Language:       en-GB

    Index:                  3
    Name:                   Windows 11 Pro
    Edition ID:             Professional
    Default Language:       en-GB
    """

    @Test func editionsAreReadFromWimlibOutput() {
        let images = WindowsInstallImage.parse(Self.wimInfo)

        #expect(images.map(\.index) == [1, 2, 3])
        #expect(images.map(\.editionID) == ["Core", "CoreSingleLanguage", "Professional"])
        #expect(images.allSatisfy { $0.defaultLanguage == "en-GB" })
    }

    @Test func proIsPreferredOverHome() throws {
        let images = WindowsInstallImage.parse(Self.wimInfo)

        #expect(WindowsInstallImage.preferred(in: images)?.index == 3)
        #expect(WindowsInstallImage.preferred(in: images.filter { $0.editionID != "Professional" })?.index == 1)
        #expect(WindowsInstallImage.preferred(in: images.filter { $0.editionID == "CoreSingleLanguage" }) == nil)
    }

    // MARK: - Answer File

    private let image = WindowsInstallImage(index: 3, name: "Windows 11 Pro", editionID: "Professional", defaultLanguage: "en-US")

    @Test func answerFileWithoutSetupLeavesWindowsSetupInteractive() throws {
        let xml = WindowsAnswerFile.xml()

        _ = try XMLDocument(xmlString: xml)
        #expect(xml.contains("BypassSecureBootCheck"))
        #expect(!xml.contains("DiskConfiguration"))
        #expect(!xml.contains("oobeSystem"))
    }

    @Test func unattendedAnswerFileInstallsPreferredEditionAndSignsIn() throws {
        let setup = WindowsUnattendedSetup(accountName: "neiljohn", password: nil, locale: "en-GB", timeZone: "GMT Standard Time")

        let xml = WindowsAnswerFile.xml(setup: setup, image: image)

        _ = try XMLDocument(xmlString: xml)
        #expect(xml.contains("<Key>/IMAGE/INDEX</Key><Value>3</Value>"))
        #expect(xml.contains("<Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key>"))
        #expect(xml.contains("<Name>neiljohn</Name>"))
        #expect(xml.contains("<Username>neiljohn</Username>"))
        #expect(xml.contains("<LogonCount>999999</LogonCount>"))
        #expect(xml.contains("<HideOnlineAccountScreens>true</HideOnlineAccountScreens>"))
        #expect(xml.contains("<TimeZone>GMT Standard Time</TimeZone>"))
        #expect(xml.contains("<UserLocale>en-GB</UserLocale>"))
        #expect(xml.contains("<UILanguage>en-US</UILanguage>"))
    }

    @Test func accountWithPasswordOnlySignsInOnce() throws {
        let setup = WindowsUnattendedSetup(accountName: "neil", password: "p&ss<word>\"", locale: "en-US", timeZone: nil)

        let xml = WindowsAnswerFile.xml(setup: setup, image: image)

        let document = try XMLDocument(xmlString: xml)
        let passwords = try document.nodes(forXPath: "//*[local-name()='Password']/*[local-name()='Value']").map(\.stringValue)
        #expect(passwords == ["p&ss<word>\"", "p&ss<word>\""])
        #expect(xml.contains("<LogonCount>1</LogonCount>"))
        #expect(!xml.contains("<TimeZone>"))
    }

    @Test func editionWithoutGenericKeyIsNotInstalledUnattended() {
        let setup = WindowsUnattendedSetup(accountName: "neil")
        let education = WindowsInstallImage(index: 1, name: "Windows 11 Education", editionID: "Education", defaultLanguage: "en-US")

        #expect(!WindowsAnswerFile.xml(setup: setup, image: education).contains("oobeSystem"))
    }

    // MARK: - Status

    @Test func statusFollowsWhatWindowsReports() {
        #expect(WindowsGuestStatus(isRunning: false, messages: "signed-in\n", isInstallerAttached: false, isUnattendedInstallation: false) == .stopped)
        #expect(WindowsGuestStatus(isRunning: true, messages: "", isInstallerAttached: true, isUnattendedInstallation: false) == .installing)
        #expect(WindowsGuestStatus(isRunning: true, messages: "", isInstallerAttached: false, isUnattendedInstallation: false) == .starting)
        #expect(WindowsGuestStatus(isRunning: true, messages: "signed-in\r\n", isInstallerAttached: true, isUnattendedInstallation: false) == .signedIn)
        #expect(WindowsGuestStatus(isRunning: true, messages: "started\r\nsigned-in\r\nstarted\r\n", isInstallerAttached: true, isUnattendedInstallation: false) == .installing)
        #expect(WindowsGuestStatus(isRunning: true, messages: "started\r\nsigned-in\r\nstarted\r\nsigned-in\r\n", isInstallerAttached: false, isUnattendedInstallation: false) == .signedIn)
    }

    @Test func unattendedInstallationIsSignedInOnlyAfterRestarting() {
        #expect(WindowsGuestStatus(isRunning: true, messages: "started\r\nsigned-in\r\n", isInstallerAttached: true, isUnattendedInstallation: true) == .installing)
        #expect(WindowsGuestStatus(isRunning: true, messages: "started\r\nsigned-in\r\n", isInstallerAttached: false, isUnattendedInstallation: false) == .signedIn)
    }

    @Test func stoppedMachineHasNoProcess() throws {
        let vm = try makeWindowsMachine()
        try Data("999999".utf8).write(to: vm.qemuPIDFileURL)

        #expect(vm.qemuProcessIdentifier == nil)
        #expect(WindowsGuestStatus(for: vm) == .stopped)
    }

    // MARK: - Settings

    @Test func setupIsSavedPrivatelyAndRemoved() throws {
        let vm = try makeWindowsMachine()
        let setup = WindowsUnattendedSetup(accountName: "neiljohn", password: "secret", locale: "en-GB", timeZone: "GMT Standard Time")

        try vm.saveWindowsUnattendedSetup(setup)

        #expect(try vm.windowsUnattendedSetup() == setup)
        let permissions = try FileManager.default.attributesOfItem(atPath: vm.windowsUnattendedSetupURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        try vm.removeWindowsUnattendedSetup()
        #expect(try vm.windowsUnattendedSetup() == nil)
    }

    // MARK: - Provisioning

    @Test func provisioningRequestsAreChecked() throws {
        let installerURL = try makeTemporaryDirectory().appending(path: "Windows.iso")
        try Data("iso".utf8).write(to: installerURL)

        func request(name: String = "Windows 11", account: String = "neiljohn", disk: UInt64 = 80, memory: UInt64 = 6, installer: URL? = nil) -> WindowsVirtualMachineProvisioner.Request {
            WindowsVirtualMachineProvisioner.Request(
                name: name,
                installerURL: installer ?? installerURL,
                setup: WindowsUnattendedSetup(accountName: account),
                diskSize: disk * .storageGigabyte,
                memorySize: memory * .storageGigabyte,
                cpuCount: VBMacDevice.defaultWindows.cpuCount
            )
        }

        func failure(_ request: WindowsVirtualMachineProvisioner.Request) -> String {
            do {
                try WindowsVirtualMachineProvisioner.validate(request)
                return ""
            } catch {
                return error.localizedDescription
            }
        }

        #expect(failure(request(name: "a/b")).contains("can’t contain"))
        #expect(failure(request(name: " ")).contains("Enter a name"))
        #expect(failure(request(account: "bad@name")).contains("“@”"))
        #expect(failure(request(disk: 32)).contains("at least 64 GB"))
        #expect(failure(request(memory: 2)).contains("memory"))
        #expect(failure(request(installer: URL(filePath: "/nonexistent/Windows.iso"))).contains("no Windows installer"))
    }

    @Test func existingVirtualMachineIsNotReplaced() async throws {
        let library = try makeTemporaryDirectory()
        let existing = try VBVirtualMachine(creatingWindowsMachineAt: library.appending(path: "Windows 11.\(VBVirtualMachine.bundleExtension)"))
        let installerURL = library.appending(path: "Windows.iso")
        try Data("iso".utf8).write(to: installerURL)

        let request = WindowsVirtualMachineProvisioner.Request(name: "Windows 11", installerURL: installerURL, setup: nil)

        do {
            _ = try await WindowsVirtualMachineProvisioner.create(request, in: library) { _ in }
            Issue.record("Creating a virtual machine with the name of an existing one succeeded")
        } catch {
            #expect(error.localizedDescription.contains("already a virtual machine"))
        }
        #expect(FileManager.default.fileExists(atPath: existing.metadataDirectoryURL.path))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WindowsUnattendedSetupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeWindowsMachine() throws -> VBVirtualMachine {
        try VBVirtualMachine(creatingWindowsMachineAt: makeTemporaryDirectory().appending(path: "Windows.\(VBVirtualMachine.bundleExtension)"))
    }
}
