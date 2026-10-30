import Foundation

/// A D-Bus message, with the file descriptors that come with it.
struct DBusMessage: @unchecked Sendable {
    enum Kind: UInt8, Sendable {
        case methodCall = 1
        case methodReturn = 2
        case error = 3
        case signal = 4
    }

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8

        static let noReplyExpected = Flags(rawValue: 0x1)
        static let noAutoStart = Flags(rawValue: 0x2)
    }

    /// The longest message that's accepted. D-Bus allows 128 MiB, but the pixels of a large display that QEMU sends
    /// when it can't share them can be more than that.
    static let maximumLength = 1 << 28

    /// The part of the header that every message starts with, which says how long the rest is.
    static let fixedHeaderLength = 16

    var kind: Kind
    var flags = Flags()
    /// Set by the connection when the message is sent.
    var serial: UInt32 = 0
    var path: String?
    var interface: String?
    var member: String?
    var errorName: String?
    var replySerial: UInt32?
    var destination: String?
    var sender: String?
    var body = [DBusValue]()
    /// The descriptors that `unixFD` values in the body refer to, by index.
    var fileDescriptors = [OwnedFileDescriptor]()

    var signature: String { body.map(\.type.signature).joined() }

    static func methodCall(
        path: String,
        interface: String,
        member: String,
        body: [DBusValue] = [],
        fileDescriptors: [OwnedFileDescriptor] = []
    ) -> DBusMessage {
        DBusMessage(kind: .methodCall, path: path, interface: interface, member: member, body: body, fileDescriptors: fileDescriptors)
    }

    func reply(_ body: [DBusValue] = []) -> DBusMessage {
        DBusMessage(kind: .methodReturn, replySerial: serial, destination: sender, body: body)
    }

    func errorReply(name: String, message: String) -> DBusMessage {
        DBusMessage(kind: .error, errorName: name, replySerial: serial, destination: sender, body: [.string(message)])
    }

    /// The text of an error reply, which is the first string in its body if it has one.
    var errorMessage: String {
        body.first?.stringValue ?? ""
    }

    // MARK: - Encoding

    private enum HeaderField: UInt8 {
        case path = 1
        case interface = 2
        case member = 3
        case errorName = 4
        case replySerial = 5
        case destination = 6
        case sender = 7
        case signature = 8
        case unixFDs = 9

        var type: DBusType {
            switch self {
            case .path: .objectPath
            case .interface, .member, .errorName, .destination, .sender: .string
            case .replySerial, .unixFDs: .uint32
            case .signature: .signature
            }
        }
    }

    private static let headerFieldType = DBusType.structure([.byte, .variant])

    func encoded() throws -> Data {
        guard serial != 0 else { throw DBusError.malformedMessage("The message has no serial number.") }

        var bodyEncoder = DBusEncoder()
        for value in body {
            try bodyEncoder.encode(value)
        }

        var fields = [(HeaderField, DBusValue)]()
        if let path { fields.append((.path, .objectPath(path))) }
        if let interface { fields.append((.interface, .string(interface))) }
        if let member { fields.append((.member, .string(member))) }
        if let errorName { fields.append((.errorName, .string(errorName))) }
        if let replySerial { fields.append((.replySerial, .uint32(replySerial))) }
        if let destination { fields.append((.destination, .string(destination))) }
        if let sender { fields.append((.sender, .string(sender))) }
        if !body.isEmpty { fields.append((.signature, .signature(signature))) }
        if !fileDescriptors.isEmpty { fields.append((.unixFDs, .uint32(UInt32(fileDescriptors.count)))) }

        var encoder = DBusEncoder()
        try encoder.encode(.byte(UInt8(ascii: "l")))
        try encoder.encode(.byte(kind.rawValue))
        try encoder.encode(.byte(flags.rawValue))
        try encoder.encode(.byte(1))
        try encoder.encode(.uint32(UInt32(bodyEncoder.data.count)))
        try encoder.encode(.uint32(serial))
        try encoder.encode(.array(of: Self.headerFieldType, fields.map { .structure([.byte($0.0.rawValue), .variant($0.1)]) }))
        encoder.align(to: 8)

        var data = encoder.data
        data.append(bodyEncoder.data)

        guard data.count <= Self.maximumLength else { throw DBusError.malformedMessage("The message is too long.") }

        return data
    }

    // MARK: - Decoding

    /// How long the message is that starts with the fixed part of a header.
    static func length(fromFixedHeader header: Data) throws -> Int {
        guard header.count >= fixedHeaderLength else { throw DBusError.malformedMessage("The header is incomplete.") }

        let isLittleEndian = try Self.isLittleEndian(header[header.startIndex])
        var decoder = DBusDecoder(data: header.prefix(fixedHeaderLength), isLittleEndian: isLittleEndian, offset: 4)
        let bodyLength = Int(try decoder.decode(.uint32).uint32Value ?? 0)
        _ = try decoder.decode(.uint32)
        let fieldsLength = Int(try decoder.decode(.uint32).uint32Value ?? 0)

        let headerLength = (fixedHeaderLength + fieldsLength + 7) & ~7
        let length = headerLength + bodyLength
        guard length <= maximumLength else { throw DBusError.malformedMessage("A message is \(length) bytes long.") }

        return length
    }

    /// Decodes a whole message.
    ///
    /// - Parameter takeFileDescriptors: Called with the number of descriptors that come with the message, if any.
    static func decode(_ data: Data, takeFileDescriptors: (Int) throws -> [OwnedFileDescriptor]) throws -> DBusMessage {
        guard data.count == (try length(fromFixedHeader: data)) else { throw DBusError.malformedMessage("The message's length is wrong.") }

        let data = data.startIndex == 0 ? data : Data(data)
        var decoder = DBusDecoder(data: data, isLittleEndian: try isLittleEndian(data[0]), offset: 1)

        guard case .byte(let kindValue) = try decoder.decode(.byte),
              case .byte(let flagsValue) = try decoder.decode(.byte),
              case .byte(1) = try decoder.decode(.byte)
        else { throw DBusError.malformedMessage("The message isn't D-Bus version 1.") }

        _ = try decoder.decode(.uint32)
        guard let serial = try decoder.decode(.uint32).uint32Value, serial != 0 else {
            throw DBusError.malformedMessage("The message has no serial number.")
        }

        guard case .array(_, let fieldValues) = try decoder.decode(.array(headerFieldType)) else {
            throw DBusError.malformedMessage("The header's fields are missing.")
        }
        try decoder.align(to: 8)

        guard let kind = Kind(rawValue: kindValue) else { throw DBusError.malformedMessage("The message is of type \(kindValue).") }

        var message = DBusMessage(kind: kind, flags: Flags(rawValue: flagsValue), serial: serial)
        var signature = ""
        var fileDescriptorCount = 0

        for fieldValue in fieldValues {
            guard case .structure(let parts) = fieldValue,
                  case .byte(let code) = parts[0],
                  case .variant(let value) = parts[1]
            else { throw DBusError.malformedMessage("A header field is malformed.") }

            /// Fields that D-Bus may add later are ignored.
            guard let field = HeaderField(rawValue: code) else { continue }
            guard value.type == field.type else {
                throw DBusError.malformedMessage("Header field \(code) is a \(value.type.signature).")
            }

            switch (field, value) {
            case (.path, .objectPath(let path)): message.path = path
            case (.interface, .string(let interface)): message.interface = interface
            case (.member, .string(let member)): message.member = member
            case (.errorName, .string(let errorName)): message.errorName = errorName
            case (.replySerial, .uint32(let replySerial)): message.replySerial = replySerial
            case (.destination, .string(let destination)): message.destination = destination
            case (.sender, .string(let sender)): message.sender = sender
            case (.signature, .signature(let value)): signature = value
            case (.unixFDs, .uint32(let count)): fileDescriptorCount = Int(count)
            default: break
            }
        }

        try message.validateRequiredFields()

        message.fileDescriptors = fileDescriptorCount > 0 ? try takeFileDescriptors(fileDescriptorCount) : []

        for type in try DBusType.types(in: signature) {
            message.body.append(try decoder.decode(type))
        }
        guard decoder.isAtEnd else { throw DBusError.malformedMessage("The body is longer than its signature says.") }

        return message
    }

    private func validateRequiredFields() throws {
        let isComplete = switch kind {
        case .methodCall: path != nil && member != nil
        case .methodReturn: replySerial != nil
        case .error: errorName != nil && replySerial != nil
        case .signal: path != nil && interface != nil && member != nil
        }

        guard isComplete else { throw DBusError.malformedMessage("A message of type \(kind.rawValue) is missing header fields.") }
    }

    private static func isLittleEndian(_ marker: UInt8) throws -> Bool {
        switch marker {
        case UInt8(ascii: "l"): return true
        case UInt8(ascii: "B"): return false
        default: throw DBusError.malformedMessage("The message's byte order is \(marker).")
        }
    }
}
