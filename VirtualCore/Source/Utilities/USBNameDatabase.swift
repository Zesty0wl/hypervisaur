import Foundation

/// Vendor and product names for USB devices from the USB ID Repository's `usb.ids` list.
///
/// The list has a line for each vendor, starting with its four digit hexadecimal ID followed by two spaces and its name,
/// then a line for each of its products, indented with a tab. Comments start with `#`, and the sections after the devices,
/// such as device classes, start with a letter instead of an ID.
public struct USBNameDatabase: Sendable {
    public struct Vendor: Sendable {
        public var name: String
        public var products: [UInt16: String]
    }

    private var vendors: [UInt16: Vendor]

    public static let empty = USBNameDatabase(vendors: [:])

    private init(vendors: [UInt16: Vendor]) {
        self.vendors = vendors
    }

    public init(contents: String) {
        var vendors = [UInt16: Vendor]()
        var currentVendorID: UInt16?

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !line.hasPrefix("#") else { continue }

            if line.hasPrefix("\t") {
                /// Interfaces of a product are indented twice, and aren't needed.
                guard !line.hasPrefix("\t\t"), let vendorID = currentVendorID,
                      let (productID, name) = Self.entry(in: line.dropFirst())
                else { continue }

                vendors[vendorID]?.products[productID] = name
            } else if let (vendorID, name) = Self.entry(in: line[...]) {
                vendors[vendorID] = Vendor(name: name, products: [:])
                currentVendorID = vendorID
            } else {
                /// The device list ends where the first section that doesn't start with an ID begins.
                guard vendors.isEmpty else { break }
            }
        }

        self.vendors = vendors
    }

    public func vendor(id: UInt16) -> Vendor? {
        vendors[id]
    }

    /// The product's name, or the vendor's name for a product that isn't in the list.
    public func displayName(vendorID: UInt16, productID: UInt16) -> String? {
        guard let vendor = vendors[vendorID] else { return nil }
        return vendor.products[productID] ?? "\(vendor.name) Device"
    }

    private static func entry(in line: Substring) -> (UInt16, String)? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].count == 4, let id = UInt16(parts[0], radix: 16) else { return nil }

        let name = parts[1].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (id, name)
    }
}

public extension USBNameDatabase {
    /// Loads the list that was downloaded most recently, downloading it again once it's a week old.
    struct Store: Sendable {
        public var remoteURL: URL
        public var cacheURL: URL
        public var maximumAge: TimeInterval = 7 * 24 * 60 * 60

        public init(remoteURL: URL, cacheURL: URL) {
            self.remoteURL = remoteURL
            self.cacheURL = cacheURL
        }

        public func cached() -> USBNameDatabase? {
            guard let data = try? Data(contentsOf: cacheURL) else { return nil }
            return USBNameDatabase(contents: String(decoding: data, as: UTF8.self))
        }

        public var needsRefresh: Bool {
            guard let modified = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return true }
            return Date.now.timeIntervalSince(modified) > maximumAge
        }

        public func refreshed() async throws -> USBNameDatabase {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)

            if let response = response as? HTTPURLResponse, response.statusCode != 200 {
                throw URLError(.badServerResponse)
            }

            let database = USBNameDatabase(contents: String(decoding: data, as: UTF8.self))
            guard !database.vendors.isEmpty else { throw URLError(.cannotParseResponse) }

            try data.write(to: cacheURL, options: .atomic)

            return database
        }
    }
}
