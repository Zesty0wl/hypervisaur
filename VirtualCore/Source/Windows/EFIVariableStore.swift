import Foundation

/// Reads the UEFI variables that EDK II keeps in a virtual machine's variable store file.
struct EFIVariableStore {
    struct Variable: Hashable {
        var name: String
        var vendor: UUID
        var data: Data
    }

    static let globalVariableVendor = UUID(uuidString: "8BE4DF61-93CA-11D2-AA0D-00E098032B8C")!

    private static let authenticatedStoreSignature = UUID(uuidString: "AAF32C78-947B-439A-A180-2E144EC37792")!
    private static let storeSignature = UUID(uuidString: "DDCF3616-3275-4164-98B6-FE85707FFE7D")!

    private static let variableStartID: UInt16 = 0x55AA
    private static let addedState: UInt8 = 0x3F
    /// A variable that's being replaced, which remains valid until its replacement has been added.
    private static let inDeletedTransitionState: UInt8 = 0x3E

    let variables: [Variable]

    init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let firmwareVolumeHeader = try handle.read(upToCount: 64) ?? Data()
        guard firmwareVolumeHeader.count == 64 else { throw Failure("The UEFI variable store is truncated.") }

        let headerLength = Int(firmwareVolumeHeader.littleEndian(UInt16.self, at: 48))
        try handle.seek(toOffset: UInt64(headerLength + 16))
        let sizeData = try handle.read(upToCount: 4) ?? Data()
        guard sizeData.count == 4 else { throw Failure("The UEFI variable store is truncated.") }

        let storeSize = Int(sizeData.littleEndian(UInt32.self, at: 0))
        guard storeSize < 64 * 1024 * 1024 else { throw Failure("The UEFI variable store is invalid.") }

        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: headerLength + storeSize) ?? Data()

        try self.init(data: data)
    }

    init(data: Data) throws {
        guard data.count >= 64, data[data.startIndex + 40..<data.startIndex + 44] == Data("_FVH".utf8) else {
            throw Failure("The UEFI variable store doesn't have a firmware volume header.")
        }

        let storeOffset = Int(data.littleEndian(UInt16.self, at: 48))
        guard data.count >= storeOffset + 28 else { throw Failure("The UEFI variable store is truncated.") }

        let signature = data.efiGUID(at: storeOffset)
        let isAuthenticated: Bool
        switch signature {
        case Self.authenticatedStoreSignature: isAuthenticated = true
        case Self.storeSignature: isAuthenticated = false
        default: throw Failure("The UEFI variable store has an unknown format.")
        }

        let storeEnd = min(data.count, storeOffset + Int(data.littleEndian(UInt32.self, at: storeOffset + 16)))
        let headerSize = isAuthenticated ? 60 : 32
        let nameSizeOffset = isAuthenticated ? 36 : 8
        let vendorOffset = isAuthenticated ? 44 : 16

        var variables = [Variable]()
        var offset = storeOffset + 28

        while offset + headerSize <= storeEnd, data.littleEndian(UInt16.self, at: offset) == Self.variableStartID {
            let state = data[data.startIndex + offset + 2]
            let nameSize = Int(data.littleEndian(UInt32.self, at: offset + nameSizeOffset))
            let dataSize = Int(data.littleEndian(UInt32.self, at: offset + nameSizeOffset + 4))

            let nameStart = offset + headerSize
            let dataStart = nameStart + nameSize
            let end = dataStart + dataSize
            guard end <= storeEnd else { break }

            if state == Self.addedState || state == Self.inDeletedTransitionState {
                let nameCodeUnits = stride(from: nameStart, to: dataStart - 1, by: 2).map { data.littleEndian(UInt16.self, at: $0) }
                let name = String(decoding: nameCodeUnits, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))

                variables.append(Variable(
                    name: name,
                    vendor: data.efiGUID(at: offset + vendorOffset),
                    data: Data(data[data.startIndex + dataStart..<data.startIndex + end])
                ))
            }

            offset = (end + 3) & ~3
        }

        self.variables = variables
    }

    /// The descriptions of the firmware's boot options, such as "Windows Boot Manager".
    var bootOptionDescriptions: [String] {
        variables
            .filter { $0.vendor == Self.globalVariableVendor && $0.isBootOption }
            .compactMap(\.loadOptionDescription)
    }
}

private extension EFIVariableStore.Variable {
    var isBootOption: Bool {
        name.count == 8 && name.hasPrefix("Boot") && name.dropFirst(4).allSatisfy(\.isHexDigit)
    }

    /// An EFI_LOAD_OPTION starts with 32-bit attributes and a 16-bit device path length, followed by a null-terminated UTF-16 description.
    var loadOptionDescription: String? {
        guard data.count > 6 else { return nil }

        var codeUnits = [UInt16]()
        var offset = 6
        while offset + 1 < data.count {
            let codeUnit = data.littleEndian(UInt16.self, at: offset)
            guard codeUnit != 0 else { break }
            codeUnits.append(codeUnit)
            offset += 2
        }

        return String(decoding: codeUnits, as: UTF16.self)
    }
}

private extension Data {
    func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(self[startIndex + offset + index]) << (index * 8)
        }
        return value
    }

    /// EFI GUIDs store their first three fields in little-endian order.
    func efiGUID(at offset: Int) -> UUID {
        let bytes = Array(self[startIndex + offset..<startIndex + offset + 16])
        let ordered = [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8..<16]
        return UUID(uuid: (
            ordered[0], ordered[1], ordered[2], ordered[3], ordered[4], ordered[5], ordered[6], ordered[7],
            ordered[8], ordered[9], ordered[10], ordered[11], ordered[12], ordered[13], ordered[14], ordered[15]
        ))
    }
}
