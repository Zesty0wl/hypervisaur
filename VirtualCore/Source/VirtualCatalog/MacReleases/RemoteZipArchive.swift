import Foundation
import Compression

/// Reads single files out of a zip archive on a web server, such as the build manifest in a macOS restore image,
/// downloading only the parts of the archive that it needs.
struct RemoteZipArchive: Sendable {
    /// Reads bytes from the archive.
    typealias ByteReader = @Sendable (_ range: Range<UInt64>) async throws -> Data

    /// The size of the archive in bytes.
    let length: UInt64

    private let read: ByteReader

    init(length: UInt64, read: @escaping ByteReader) {
        self.length = length
        self.read = read
    }

    /// Opens an archive on a server that supports range requests, as Apple's servers do.
    init(url: URL, session: URLSession = .shared) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "HEAD"

        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw Failure("The server responded with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        guard let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init), length > 0 else {
            throw Failure("The server didn’t say how large the archive is.")
        }

        self.init(length: length) { range in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 206, UInt64(data.count) == UInt64(range.count) else {
                throw Failure("The server didn’t return part of the archive.")
            }
            return data
        }
    }

    /// The contents of a file in the archive.
    /// - Parameters:
    ///   - path: The file's path in the archive.
    ///   - maximumSize: The largest file that's expected, so that a damaged or unexpected archive can't use too much memory.
    func contents(of path: String, maximumSize: Int) async throws -> Data {
        let directory = try await centralDirectory()
        guard let entry = try Self.entries(in: directory).first(where: { $0.path == path }) else {
            throw Failure("The archive doesn’t contain \(path).")
        }
        guard entry.uncompressedSize <= UInt64(maximumSize), entry.compressedSize <= UInt64(maximumSize) else {
            throw Failure("\(path) is \(entry.uncompressedSize) bytes, which is larger than expected.")
        }

        let localHeader = try await bytes(entry.localHeaderOffset, count: 30)
        guard try localHeader.littleEndian(UInt32.self, at: 0) == Signature.localFileHeader else {
            throw Failure("The archive is damaged.")
        }
        let dataOffset = entry.localHeaderOffset + 30
            + UInt64(try localHeader.littleEndian(UInt16.self, at: 26))
            + UInt64(try localHeader.littleEndian(UInt16.self, at: 28))

        let stored = try await bytes(dataOffset, count: entry.compressedSize)

        switch entry.compressionMethod {
        case 0:
            guard UInt64(stored.count) == entry.uncompressedSize else { throw Failure("The archive is damaged.") }
            return stored
        case 8:
            return try Self.inflate(stored, size: Int(entry.uncompressedSize))
        default:
            throw Failure("\(path) is compressed in a way that isn’t supported.")
        }
    }

    // MARK: - Archive Structure

    private enum Signature {
        static let localFileHeader: UInt32 = 0x04034b50
        static let centralDirectoryEntry: UInt32 = 0x02014b50
        static let endOfCentralDirectory: UInt32 = 0x06054b50
        static let zip64EndOfCentralDirectory: UInt32 = 0x06064b50
        static let zip64EndOfCentralDirectoryLocator: UInt32 = 0x07064b50
    }

    /// Restore images have a central directory of a few hundred kilobytes.
    static let maximumCentralDirectorySize: UInt64 = 16 * 1024 * 1024

    struct Entry: Hashable {
        var path: String
        var compressionMethod: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
    }

    private func bytes(_ offset: UInt64, count: UInt64) async throws -> Data {
        guard offset <= length, count <= length - offset else { throw Failure("The archive is damaged.") }
        guard count > 0 else { return Data() }
        return try await read(offset..<offset + count)
    }

    private func centralDirectory() async throws -> Data {
        /// The end of central directory record is followed by a comment of up to 64 KB, and preceded by a zip64 locator.
        let tailLength = min(length, 22 + 0xFFFF + 20)
        let tail = try await bytes(length - tailLength, count: tailLength)

        guard let end = Self.lastIndex(of: Signature.endOfCentralDirectory, in: tail, searchingBackFrom: tail.count - 22) else {
            throw Failure("The file isn’t a zip archive.")
        }

        var size = UInt64(try tail.littleEndian(UInt32.self, at: end + 12))
        var offset = UInt64(try tail.littleEndian(UInt32.self, at: end + 16))

        if size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            let locator = end - 20
            guard locator >= 0, try tail.littleEndian(UInt32.self, at: locator) == Signature.zip64EndOfCentralDirectoryLocator else {
                throw Failure("The archive is damaged.")
            }
            let recordOffset = try tail.littleEndian(UInt64.self, at: locator + 8)
            let record = try await bytes(recordOffset, count: 56)
            guard try record.littleEndian(UInt32.self, at: 0) == Signature.zip64EndOfCentralDirectory else {
                throw Failure("The archive is damaged.")
            }
            size = try record.littleEndian(UInt64.self, at: 40)
            offset = try record.littleEndian(UInt64.self, at: 48)
        }

        guard size <= Self.maximumCentralDirectorySize else {
            throw Failure("The archive’s list of files is \(size) bytes, which is larger than expected.")
        }

        return try await bytes(offset, count: size)
    }

    static func entries(in directory: Data) throws -> [Entry] {
        var entries = [Entry]()
        var position = 0

        while position + 46 <= directory.count {
            guard try directory.littleEndian(UInt32.self, at: position) == Signature.centralDirectoryEntry else {
                throw Failure("The archive is damaged.")
            }

            let nameLength = Int(try directory.littleEndian(UInt16.self, at: position + 28))
            let extraLength = Int(try directory.littleEndian(UInt16.self, at: position + 30))
            let commentLength = Int(try directory.littleEndian(UInt16.self, at: position + 32))

            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw Failure("The archive is damaged.") }

            let nameStartIndex = directory.startIndex + nameStart
            var entry = Entry(
                path: String(decoding: directory[nameStartIndex..<nameStartIndex + nameLength], as: UTF8.self),
                compressionMethod: try directory.littleEndian(UInt16.self, at: position + 10),
                compressedSize: UInt64(try directory.littleEndian(UInt32.self, at: position + 20)),
                uncompressedSize: UInt64(try directory.littleEndian(UInt32.self, at: position + 24)),
                localHeaderOffset: UInt64(try directory.littleEndian(UInt32.self, at: position + 42))
            )

            if entry.uncompressedSize == 0xFFFF_FFFF || entry.compressedSize == 0xFFFF_FFFF || entry.localHeaderOffset == 0xFFFF_FFFF {
                try readZip64Fields(into: &entry, from: directory, extraFieldsAt: extraStart, length: extraLength)
            }

            entries.append(entry)
            position = next
        }

        return entries
    }

    /// Sizes and offsets that don't fit in 32 bits are in a zip64 extra field, in this order, with only the ones that didn't fit.
    private static func readZip64Fields(into entry: inout Entry, from directory: Data, extraFieldsAt start: Int, length: Int) throws {
        var position = start
        let end = start + length

        while position + 4 <= end {
            let id = try directory.littleEndian(UInt16.self, at: position)
            let size = Int(try directory.littleEndian(UInt16.self, at: position + 2))
            guard position + 4 + size <= end else { break }

            if id == 0x0001 {
                var field = position + 4
                func next() throws -> UInt64 {
                    guard field + 8 <= position + 4 + size else { throw Failure("The archive is damaged.") }
                    defer { field += 8 }
                    return try directory.littleEndian(UInt64.self, at: field)
                }
                if entry.uncompressedSize == 0xFFFF_FFFF { entry.uncompressedSize = try next() }
                if entry.compressedSize == 0xFFFF_FFFF { entry.compressedSize = try next() }
                if entry.localHeaderOffset == 0xFFFF_FFFF { entry.localHeaderOffset = try next() }
                return
            }

            position += 4 + size
        }

        throw Failure("The archive is damaged.")
    }

    private static func lastIndex(of signature: UInt32, in data: Data, searchingBackFrom start: Int) -> Int? {
        guard start >= 0 else { return nil }
        for position in stride(from: start, through: 0, by: -1) {
            if (try? data.littleEndian(UInt32.self, at: position)) == signature {
                return position
            }
        }
        return nil
    }

    /// Zip archives use raw DEFLATE, which is what `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !data.isEmpty else { throw Failure("The archive is damaged.") }

        var output = Data(count: size)
        let decodedSize = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize == size else { throw Failure("The archive is damaged.") }
        return output
    }
}

private extension Data {
    func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { throw Failure("The archive is damaged.") }

        var value = T.zero
        for byte in 0..<size {
            value |= T(self[startIndex + offset + byte]) << (byte * 8)
        }
        return value
    }
}
