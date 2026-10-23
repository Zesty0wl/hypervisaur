import Foundation
import Testing
@testable import VirtualCore

struct USBNameDatabaseTests {
    private static let list = """
    #
    #\tList of USB ID's
    #
    # Syntax:
    # vendor  vendor_name
    #\tdevice  device_name\t\t\t\t<-- single tab
    #\t\tinterface  interface_name\t\t<-- two tabs

    05ac  Apple, Inc.
    \t12a8  iPhone 5/5C/5S/6/SE/7/8/X/XR
    \t\t00  Interface Name
    \t8600  iBridge
    0781  SanDisk Corp.
    \t5581  Ultra

    # List of known device classes, subclasses and protocols
    C 00  (Defined at Interface level)
    \t01  Audio
    """

    @Test func productsAreNamed() {
        let database = USBNameDatabase(contents: Self.list)

        #expect(database.displayName(vendorID: 0x05AC, productID: 0x8600) == "iBridge")
        #expect(database.displayName(vendorID: 0x0781, productID: 0x5581) == "Ultra")
    }

    @Test func unknownProductsAreNamedAfterTheirVendor() {
        let database = USBNameDatabase(contents: Self.list)

        #expect(database.displayName(vendorID: 0x05AC, productID: 0x0001) == "Apple, Inc. Device")
        #expect(database.displayName(vendorID: 0x1234, productID: 0x0001) == nil)
    }

    @Test func interfacesAndClassesAreIgnored() {
        let database = USBNameDatabase(contents: Self.list)

        #expect(database.vendor(id: 0x05AC)?.products.count == 2)
        #expect(database.vendor(id: 0x0000) == nil)
    }

    @Test func cachedListIsLoadedFromDisk() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: "usb-\(UUID().uuidString).ids")
        try Data(Self.list.utf8).write(to: cacheURL)
        let store = USBNameDatabase.Store(remoteURL: URL(string: "https://example.com/usb.ids")!, cacheURL: cacheURL)

        #expect(store.cached()?.displayName(vendorID: 0x0781, productID: 0x5581) == "Ultra")
        #expect(!store.needsRefresh)
    }
}
