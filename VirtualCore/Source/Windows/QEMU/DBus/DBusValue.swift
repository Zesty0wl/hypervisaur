import Foundation

/// Something that went wrong with a D-Bus connection or message.
enum DBusError: LocalizedError, Equatable {
    case invalidSignature(String)
    case malformedMessage(String)
    case authenticationFailed(String)
    case connectionClosed
    /// The peer replied to a method call with an error.
    case remote(name: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidSignature(let signature):
            "The D-Bus type signature “\(signature)” isn’t valid."
        case .malformedMessage(let reason):
            "A D-Bus message was malformed: \(reason)"
        case .authenticationFailed(let reason):
            "The D-Bus connection couldn’t be authenticated: \(reason)"
        case .connectionClosed:
            "The D-Bus connection was closed."
        case .remote(let name, let message):
            "\(name): \(message)"
        }
    }
}

/// The type of a value in a D-Bus message, as written in a type signature.
indirect enum DBusType: Equatable, Sendable {
    case byte
    case boolean
    case int16
    case uint16
    case int32
    case uint32
    case int64
    case uint64
    case double
    case string
    case objectPath
    case signature
    /// An index into the file descriptors that come with the message.
    case unixFD
    case variant
    case array(DBusType)
    case structure([DBusType])
    /// An entry of a dictionary, which is an array of them.
    case dictEntry(key: DBusType, value: DBusType)

    /// The longest signature that D-Bus allows.
    static let maximumSignatureLength = 255

    /// How deeply arrays, and structures, can each be nested in a signature.
    static let maximumNesting = 32

    var signature: String {
        switch self {
        case .byte: "y"
        case .boolean: "b"
        case .int16: "n"
        case .uint16: "q"
        case .int32: "i"
        case .uint32: "u"
        case .int64: "x"
        case .uint64: "t"
        case .double: "d"
        case .string: "s"
        case .objectPath: "o"
        case .signature: "g"
        case .unixFD: "h"
        case .variant: "v"
        case .array(let element): "a" + element.signature
        case .structure(let fields): "(" + fields.map(\.signature).joined() + ")"
        case .dictEntry(let key, let value): "{" + key.signature + value.signature + "}"
        }
    }

    /// The boundary, counted from the start of the message, that values of the type start on.
    var alignment: Int {
        switch self {
        case .byte, .signature, .variant: 1
        case .int16, .uint16: 2
        case .boolean, .int32, .uint32, .string, .objectPath, .unixFD, .array: 4
        case .int64, .uint64, .double, .structure, .dictEntry: 8
        }
    }

    /// Whether the type can be a dictionary's key.
    var isBasic: Bool {
        switch self {
        case .variant, .array, .structure, .dictEntry: false
        default: true
        }
    }

    /// The types of the values that a signature describes, in order.
    static func types(in signature: String) throws -> [DBusType] {
        let characters = Array(signature.utf8)
        guard characters.count <= maximumSignatureLength else { throw DBusError.invalidSignature(signature) }

        var parser = SignatureParser(characters: characters, signature: signature)
        var types = [DBusType]()
        while !parser.isAtEnd {
            types.append(try parser.parseType(arrayDepth: 0, structureDepth: 0))
        }
        return types
    }

    private struct SignatureParser {
        let characters: [UInt8]
        let signature: String
        var index = 0

        var isAtEnd: Bool { index == characters.count }

        private var invalid: DBusError { .invalidSignature(signature) }

        mutating func parseType(arrayDepth: Int, structureDepth: Int) throws -> DBusType {
            guard index < characters.count else { throw invalid }
            let character = characters[index]
            index += 1

            switch character {
            case UInt8(ascii: "y"): return .byte
            case UInt8(ascii: "b"): return .boolean
            case UInt8(ascii: "n"): return .int16
            case UInt8(ascii: "q"): return .uint16
            case UInt8(ascii: "i"): return .int32
            case UInt8(ascii: "u"): return .uint32
            case UInt8(ascii: "x"): return .int64
            case UInt8(ascii: "t"): return .uint64
            case UInt8(ascii: "d"): return .double
            case UInt8(ascii: "s"): return .string
            case UInt8(ascii: "o"): return .objectPath
            case UInt8(ascii: "g"): return .signature
            case UInt8(ascii: "h"): return .unixFD
            case UInt8(ascii: "v"): return .variant
            case UInt8(ascii: "a"):
                guard arrayDepth < DBusType.maximumNesting else { throw invalid }

                /// Dictionary entries can only be the elements of an array.
                if index < characters.count, characters[index] == UInt8(ascii: "{") {
                    index += 1
                    let key = try parseType(arrayDepth: arrayDepth + 1, structureDepth: structureDepth + 1)
                    let value = try parseType(arrayDepth: arrayDepth + 1, structureDepth: structureDepth + 1)
                    guard key.isBasic, index < characters.count, characters[index] == UInt8(ascii: "}") else { throw invalid }
                    index += 1
                    return .array(.dictEntry(key: key, value: value))
                }

                return .array(try parseType(arrayDepth: arrayDepth + 1, structureDepth: structureDepth))
            case UInt8(ascii: "("):
                guard structureDepth < DBusType.maximumNesting else { throw invalid }

                var fields = [DBusType]()
                while index < characters.count, characters[index] != UInt8(ascii: ")") {
                    fields.append(try parseType(arrayDepth: arrayDepth, structureDepth: structureDepth + 1))
                }
                guard !fields.isEmpty, index < characters.count else { throw invalid }
                index += 1
                return .structure(fields)
            default:
                throw invalid
            }
        }
    }
}

/// A value in a D-Bus message.
indirect enum DBusValue: Equatable, Sendable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    /// An index into the file descriptors that come with the message.
    case unixFD(UInt32)
    case variant(DBusValue)
    /// An array of bytes, which is how they're always decoded, since they can be as big as a display's pixels.
    case bytes(Data)
    case array(of: DBusType, [DBusValue])
    case structure([DBusValue])
    case dictEntry(DBusValue, DBusValue)

    var type: DBusType {
        switch self {
        case .byte: .byte
        case .boolean: .boolean
        case .int16: .int16
        case .uint16: .uint16
        case .int32: .int32
        case .uint32: .uint32
        case .int64: .int64
        case .uint64: .uint64
        case .double: .double
        case .string: .string
        case .objectPath: .objectPath
        case .signature: .signature
        case .unixFD: .unixFD
        case .variant: .variant
        case .bytes: .array(.byte)
        case .array(let element, _): .array(element)
        case .structure(let fields): .structure(fields.map(\.type))
        case .dictEntry(let key, let value): .dictEntry(key: key.type, value: value.type)
        }
    }

    static func strings(_ strings: [String]) -> DBusValue {
        .array(of: .string, strings.map { .string($0) })
    }

    var int32Value: Int32? {
        if case .int32(let value) = self { value } else { nil }
    }

    var uint32Value: UInt32? {
        if case .uint32(let value) = self { value } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var bytesValue: Data? {
        if case .bytes(let value) = self { value } else { nil }
    }

    var unixFDIndex: Int? {
        if case .unixFD(let index) = self { Int(index) } else { nil }
    }
}

/// Writes values in D-Bus's little-endian wire format.
///
/// Values are aligned from the start of what's written, so a message's body is written separately: it starts on an
/// 8-byte boundary, the strictest alignment there is.
struct DBusEncoder {
    /// The longest array that D-Bus allows.
    static let maximumArrayLength = 1 << 26

    private(set) var data = Data()

    mutating func encode(_ value: DBusValue) throws {
        align(to: value.type.alignment)

        switch value {
        case .byte(let value):
            data.append(value)
        case .boolean(let value):
            append(UInt32(value ? 1 : 0))
        case .int16(let value):
            append(value)
        case .uint16(let value):
            append(value)
        case .int32(let value):
            append(value)
        case .uint32(let value):
            append(value)
        case .int64(let value):
            append(value)
        case .uint64(let value):
            append(value)
        case .double(let value):
            append(value.bitPattern)
        case .string(let string), .objectPath(let string):
            let bytes = Data(string.utf8)
            guard !bytes.contains(0) else { throw DBusError.malformedMessage("A string contains a null character.") }
            append(UInt32(bytes.count))
            data.append(bytes)
            data.append(0)
        case .signature(let signature):
            try appendSignature(signature)
        case .unixFD(let index):
            append(index)
        case .variant(let value):
            try appendSignature(value.type.signature)
            try encode(value)
        case .bytes(let bytes):
            guard bytes.count <= Self.maximumArrayLength else { throw DBusError.malformedMessage("An array is too long.") }
            append(UInt32(bytes.count))
            data.append(bytes)
        case .array(let element, let values):
            let lengthOffset = data.count
            append(UInt32(0))
            align(to: element.alignment)

            let start = data.count
            for value in values {
                guard value.type == element else {
                    throw DBusError.malformedMessage("An array of \(element.signature) contains a \(value.type.signature).")
                }
                try encode(value)
            }

            let length = data.count - start
            guard length <= Self.maximumArrayLength else { throw DBusError.malformedMessage("An array is too long.") }
            withUnsafeBytes(of: UInt32(length).littleEndian) { data.replaceSubrange(lengthOffset..<lengthOffset + 4, with: $0) }
        case .structure(let fields):
            for field in fields {
                try encode(field)
            }
        case .dictEntry(let key, let value):
            guard key.type.isBasic else { throw DBusError.malformedMessage("A dictionary's key is a \(key.type.signature).") }
            try encode(key)
            try encode(value)
        }
    }

    mutating func align(to alignment: Int) {
        let padding = (alignment - data.count % alignment) % alignment
        data.append(contentsOf: repeatElement(0, count: padding))
    }

    private mutating func appendSignature(_ signature: String) throws {
        _ = try DBusType.types(in: signature)
        data.append(UInt8(signature.utf8.count))
        data.append(contentsOf: signature.utf8)
        data.append(0)
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Reads values in D-Bus's wire format, in either byte order.
struct DBusDecoder {
    /// How deeply values can be nested, counting variants, which the specification limits to twice ``DBusType/maximumNesting``.
    private static let maximumDepth = 2 * DBusType.maximumNesting

    private let data: Data
    private let isLittleEndian: Bool
    /// Where the next value is read from, counted from the start of the data, which alignment is counted from too.
    private(set) var offset: Int

    init(data: Data, isLittleEndian: Bool, offset: Int = 0) {
        self.data = data.startIndex == 0 ? data : Data(data)
        self.isLittleEndian = isLittleEndian
        self.offset = offset
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func decode(_ type: DBusType) throws -> DBusValue {
        try decode(type, depth: 0)
    }

    private mutating func decode(_ type: DBusType, depth: Int) throws -> DBusValue {
        guard depth <= Self.maximumDepth else { throw DBusError.malformedMessage("Values are nested too deeply.") }

        try align(to: type.alignment)

        switch type {
        case .byte:
            return .byte(try readByte())
        case .boolean:
            let value = try read(UInt32.self)
            guard value <= 1 else { throw DBusError.malformedMessage("A boolean is \(value).") }
            return .boolean(value == 1)
        case .int16:
            return .int16(try read(Int16.self))
        case .uint16:
            return .uint16(try read(UInt16.self))
        case .int32:
            return .int32(try read(Int32.self))
        case .uint32:
            return .uint32(try read(UInt32.self))
        case .int64:
            return .int64(try read(Int64.self))
        case .uint64:
            return .uint64(try read(UInt64.self))
        case .double:
            return .double(Double(bitPattern: try read(UInt64.self)))
        case .string:
            return .string(try readString(length: Int(try read(UInt32.self))))
        case .objectPath:
            return .objectPath(try readString(length: Int(try read(UInt32.self))))
        case .signature:
            return .signature(try readSignature())
        case .unixFD:
            return .unixFD(try read(UInt32.self))
        case .variant:
            let signature = try readSignature()
            let types = try DBusType.types(in: signature)
            guard types.count == 1 else { throw DBusError.malformedMessage("A variant holds “\(signature)”.") }
            return .variant(try decode(types[0], depth: depth + 1))
        case .array(let element):
            let length = Int(try read(UInt32.self))
            try align(to: element.alignment)
            guard length <= data.count - offset else { throw DBusError.malformedMessage("An array is longer than the message.") }
            let end = offset + length

            if element == .byte {
                defer { offset = end }
                return .bytes(data.subdata(in: offset..<end))
            }

            var values = [DBusValue]()
            while offset < end {
                values.append(try decode(element, depth: depth + 1))
            }
            guard offset == end else { throw DBusError.malformedMessage("An array's elements don't fill it.") }
            return .array(of: element, values)
        case .structure(let fields):
            return .structure(try fields.map { try decode($0, depth: depth + 1) })
        case .dictEntry(let key, let value):
            return .dictEntry(try decode(key, depth: depth + 1), try decode(value, depth: depth + 1))
        }
    }

    /// Skips the padding before the next value, which has to be zeros.
    mutating func align(to alignment: Int) throws {
        let padding = (alignment - offset % alignment) % alignment
        guard padding <= data.count - offset else { throw DBusError.malformedMessage("The message ends in padding.") }
        guard data[offset..<offset + padding].allSatisfy({ $0 == 0 }) else {
            throw DBusError.malformedMessage("Padding isn't zeros.")
        }
        offset += padding
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw DBusError.malformedMessage("The message ends too soon.") }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= data.count - offset else { throw DBusError.malformedMessage("The message ends too soon.") }

        var value = T.zero
        withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: offset..<offset + size)
        }
        offset += size

        return isLittleEndian ? T(littleEndian: value) : T(bigEndian: value)
    }

    private mutating func readSignature() throws -> String {
        let signature = try readString(length: Int(try readByte()))
        _ = try DBusType.types(in: signature)
        return signature
    }

    /// Reads a string's bytes and the null character after them.
    private mutating func readString(length: Int) throws -> String {
        guard length < data.count - offset else { throw DBusError.malformedMessage("A string is longer than the message.") }

        let bytes = data[offset..<offset + length]
        guard data[offset + length] == 0, !bytes.contains(0), let string = String(data: bytes, encoding: .utf8) else {
            throw DBusError.malformedMessage("A string isn't valid UTF-8 ending in a null character.")
        }
        offset += length + 1

        return string
    }
}
