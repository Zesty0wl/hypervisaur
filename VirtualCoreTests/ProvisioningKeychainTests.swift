import Foundation
import Testing
@testable import VirtualCore

/// A virtual machine's configuration can come from somewhere else, such as a bundle that was imported, so the keychain item
/// it says holds the provisioning password must be checked before the password is read.
struct ProvisioningKeychainTests {
    private func configuration(service: String, account: (VBMacConfiguration) -> String) -> VBMacConfiguration {
        var configuration = VBMacConfiguration.default.guestType(.mac)
        configuration.provisioningEnabled = true
        configuration.provisioning = VBMacProvisioningConfiguration(
            fullName: "Dummy User",
            username: "dummy",
            password: KeychainReference(service: service, account: account(configuration))
        )
        return configuration
    }

    @Test(arguments: [VBMacProvisioningConfiguration.keychainItemService, "codes.rambo.VirtualBuddy.Provisioning"])
    func passwordsSavedForTheVirtualMachineAreUsed(service: String) {
        let configuration = configuration(service: service) { $0.provisioningUUID.uuidString }

        #expect(configuration.verifiedProvisioning != nil)
    }

    @Test func passwordsOfOtherServicesArentUsed() {
        let configuration = configuration(service: "com.example.mail") { $0.provisioningUUID.uuidString }

        #expect(configuration.verifiedProvisioning == nil)
    }

    @Test func passwordsSavedForOtherVirtualMachinesArentUsed() {
        let configuration = configuration(service: VBMacProvisioningConfiguration.keychainItemService) { _ in UUID().uuidString }

        #expect(configuration.verifiedProvisioning == nil)
    }

    @Test func referencesReadFromAConfigurationFileAreChecked() throws {
        let original = configuration(service: VBMacProvisioningConfiguration.keychainItemService) { $0.provisioningUUID.uuidString }
        var plist = try #require(PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(original), format: nil) as? [String: Any])
        var provisioning = try #require(plist["provisioning"] as? [String: Any])
        provisioning["password"] = KeychainReference.stringPrefix + #"{"service":"com.example.mail","account":"someone@example.com"}"#
        plist["provisioning"] = provisioning

        let decoded = try PropertyListDecoder().decode(VBMacConfiguration.self, from: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))

        #expect(decoded.provisioning?.$password.service == "com.example.mail")
        #expect(decoded.verifiedProvisioning == nil)
    }

    /// Duplicating would otherwise read the other item and save a copy of it for the new virtual machine.
    @Test func provisioningWithSomeoneElsesPasswordIsntDuplicated() throws {
        let configuration = configuration(service: "com.example.mail") { $0.provisioningUUID.uuidString }

        let copy = try configuration.duplicate()

        #expect(copy.provisioning == nil)
        #expect(copy.provisioningUUID != configuration.provisioningUUID)
    }
}
