import Foundation

/// Where a ``GuestAgentFrame/Kind/putFiles`` transfer puts its items in the guest.
public enum GuestFileDestination: UInt8, Sendable {
    /// The desktop of the user signed in at the guest's display.
    case desktop = 0
}

/// Starts an item of a transfer.
public struct GuestFileHeader: Equatable, Sendable {
    public enum ItemType: UInt8, Sendable {
        case file = 0
        case folder = 1
    }

    public var type: ItemType
    /// The size of a file in bytes, which is 0 for folders.
    public var size: UInt64
    /// POSIX permissions, or 0 when they aren't known.
    public var permissions: UInt32
    /// Seconds since 1970, or 0 when it isn't known.
    public var modificationTime: Int64
    /// The item's path relative to the transfer, with `/` between components.
    public var path: String

    public init(type: ItemType, size: UInt64, permissions: UInt32, modificationTime: Int64, path: String) {
        self.type = type
        self.size = size
        self.permissions = permissions
        self.modificationTime = modificationTime
        self.path = path
    }

    static let fixedSize = 1 + 8 + 4 + 8

    public var payload: Data {
        var data = Data(capacity: Self.fixedSize + path.utf8.count)
        data.append(type.rawValue)
        data.appendLittleEndian(size)
        data.appendLittleEndian(permissions)
        data.appendLittleEndian(UInt64(bitPattern: modificationTime))
        data.append(Data(path.utf8))
        return data
    }

    public init(payload: Data) throws {
        guard payload.count > Self.fixedSize else { throw GuestAgentError("A file's description is incomplete.") }

        let start = payload.startIndex
        guard let type = ItemType(rawValue: payload[start]) else {
            throw GuestAgentError("A file has a type that isn't known (\(payload[start])).")
        }
        self.type = type
        size = payload.littleEndianUInt64(at: start + 1)
        permissions = payload.littleEndianUInt32(at: start + 9)
        modificationTime = Int64(bitPattern: payload.littleEndianUInt64(at: start + 13))
        path = String(decoding: payload[(start + Self.fixedSize)...], as: UTF8.self)
    }

    /// The path's components, after checking that it stays inside the transfer.
    public func validatedComponents() throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else {
            throw GuestAgentError("A file in the transfer has a path that isn't allowed: “\(path)”.")
        }
        return components
    }
}

/// The size of a transfer, sent before its first item.
public struct GuestTransferSize: Equatable, Sendable {
    public var totalBytes: UInt64
    public var itemCount: UInt32

    public init(totalBytes: UInt64, itemCount: UInt32) {
        self.totalBytes = totalBytes
        self.itemCount = itemCount
    }

    public var payload: Data {
        var data = Data()
        data.appendLittleEndian(totalBytes)
        data.appendLittleEndian(itemCount)
        return data
    }

    public init(payload: Data) throws {
        guard payload.count >= 12 else { throw GuestAgentError("The size of the transfer is incomplete.") }
        totalBytes = payload.littleEndianUInt64(at: payload.startIndex)
        itemCount = payload.littleEndianUInt32(at: payload.startIndex + 8)
    }
}

/// A file or folder being dragged in the guest.
public struct GuestDragItem: Equatable, Sendable {
    public var isFolder: Bool
    /// The item's absolute path in the guest.
    public var path: String

    public init(isFolder: Bool, path: String) {
        self.isFolder = isFolder
        self.path = path
    }

    /// The item's name, which is the last component of its path. Windows paths use either kind of slash.
    public var name: String {
        let separators: Set<Character> = ["/", "\\"]
        let trimmed = path.reversed().drop(while: { separators.contains($0) }).reversed()
        let name = String(trimmed).split(whereSeparator: { separators.contains($0) }).last.map(String.init)
        return name ?? path
    }

    /// One line per item, with `f` for a file or `d` for a folder, a tab, and the item's path.
    public static func payload(for items: [GuestDragItem]) -> Data {
        Data(items.map { "\($0.isFolder ? "d" : "f")\t\($0.path)" }.joined(separator: "\n").utf8)
    }

    public static func items(from payload: Data) -> [GuestDragItem] {
        String(decoding: payload, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, parts[0] == "f" || parts[0] == "d", !parts[1].isEmpty else { return nil }
                return GuestDragItem(isFolder: parts[0] == "d", path: String(parts[1]))
            }
    }
}

public extension GuestAgentFrame {
    static func acknowledgement(_ bytes: UInt64) -> Data {
        var data = Data()
        data.appendLittleEndian(bytes)
        return data
    }

    /// How many bytes of file data an ``Kind/acknowledge`` frame says were written.
    var acknowledgedBytes: UInt64? {
        guard kind == .acknowledge, payload.count >= 8 else { return nil }
        return payload.littleEndianUInt64(at: payload.startIndex)
    }

    /// Paths, one per line, as ``Kind/getFiles`` and ``Kind/transferred`` carry them.
    static func pathList(_ paths: [String]) -> Data {
        Data(paths.joined(separator: "\n").utf8)
    }

    var pathList: [String] {
        String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}

// MARK: - Sending

/// Sends files and folders on a channel: the transfer's size, then each item, then the end of the transfer.
///
/// It runs on a thread of its own, and waits whenever the receiver hasn't acknowledged ``GuestAgentFrame/transferWindow``
/// bytes, so that the data waiting to be written never grows larger than that.
public final class GuestFileSender: @unchecked Sendable {
    private struct Item {
        var url: URL
        var header: GuestFileHeader
    }

    private let items: [Item]
    public let size: GuestTransferSize

    private let condition = NSCondition()
    private var sentBytes: UInt64 = 0
    private var acknowledgedBytes: UInt64 = 0
    private var isCancelled = false

    /// Finds the files to send. Each URL becomes a top-level item named after its last component, and folders are sent with
    /// everything in them. Symbolic links inside folders aren't sent.
    public init(urls: [URL]) throws {
        var items = [Item]()
        var totalBytes: UInt64 = 0

        func add(_ url: URL, path: String) throws {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isSymbolicLink != true else { return }

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
            let modificationTime = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)

            if values.isDirectory == true {
                items.append(Item(url: url, header: GuestFileHeader(type: .folder, size: 0, permissions: permissions, modificationTime: modificationTime, path: path)))

                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try add(child, path: path + "/" + child.lastPathComponent)
                }
            } else {
                let size = UInt64(max(values.fileSize ?? 0, 0))
                totalBytes += size
                items.append(Item(url: url, header: GuestFileHeader(type: .file, size: size, permissions: permissions, modificationTime: modificationTime, path: path)))
            }
        }

        for url in urls {
            /// A top-level symbolic link is sent as what it points to, since that's what was chosen.
            let resolved = url.resolvingSymlinksInPath()
            try add(resolved, path: url.lastPathComponent)
        }

        guard items.count <= UInt32.max else { throw GuestAgentError("There are too many files to copy at once.") }

        self.items = items
        self.size = GuestTransferSize(totalBytes: totalBytes, itemCount: UInt32(items.count))
    }

    /// Records the receiver's acknowledgement, which lets more data be sent. The receiver can't acknowledge more than the
    /// transfer holds, whatever it claims.
    public func acknowledge(_ bytes: UInt64) {
        condition.withLock {
            acknowledgedBytes = max(acknowledgedBytes, min(bytes, size.totalBytes))
            condition.broadcast()
        }
    }

    /// Stops sending, including when ``send(_:)`` is waiting for an acknowledgement.
    public func cancel() {
        condition.withLock {
            isCancelled = true
            condition.broadcast()
        }
    }

    /// Sends the transfer, blocking the calling thread until it's all sent. Throws if it's cancelled, a file can't be read,
    /// or `sendFrame` throws.
    public func send(_ sendFrame: (GuestAgentFrame.Kind, Data) throws -> Void) throws {
        try sendFrame(.transferSize, size.payload)

        for item in items {
            try checkCancelled()
            try sendFrame(.fileHeader, item.header.payload)
            guard item.header.type == .file else { continue }

            let handle = try FileHandle(forReadingFrom: item.url)
            defer { try? handle.close() }

            var remaining = item.header.size
            while remaining > 0 {
                let length = Int(min(remaining, UInt64(GuestAgentFrame.fileChunkSize)))
                try waitForWindow(toSend: UInt64(length))

                guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else {
                    throw GuestAgentError("“\(item.url.lastPathComponent)” got shorter while it was being copied.")
                }
                try sendFrame(.fileData, chunk)

                remaining -= UInt64(chunk.count)
                condition.withLock { sentBytes += UInt64(chunk.count) }
            }
        }

        try checkCancelled()
        try sendFrame(.filesEnd, Data())
    }

    private func checkCancelled() throws {
        if condition.withLock({ isCancelled }) {
            throw CancellationError()
        }
    }

    private func waitForWindow(toSend length: UInt64) throws {
        condition.lock()
        defer { condition.unlock() }

        while !isCancelled {
            let pending = sentBytes + length
            guard pending > acknowledgedBytes, pending - acknowledgedBytes > GuestAgentFrame.transferWindow else { break }
            condition.wait()
        }
        if isCancelled { throw CancellationError() }
    }
}

// MARK: - Receiving

/// Writes the items of a transfer into a folder as their frames arrive.
///
/// Every path is checked to stay inside the folder, and each item must be inside a folder that came earlier in the transfer.
/// Permissions and modification dates are applied once each item is complete.
public final class GuestFileReceiver {
    public private(set) var size: GuestTransferSize?
    /// How many bytes of file data have been written.
    public private(set) var writtenBytes: UInt64 = 0
    /// The top-level items written so far, in the order they arrived.
    public private(set) var topLevelURLs = [URL]()
    public private(set) var isComplete = false

    private let rootURL: URL
    private let topLevelName: (String) -> String
    /// The paths of the folders and files written so far, as they were sent.
    private var folders = Set<String>()
    private var files = Set<String>()
    private var topLevelNames = [String: String]()
    private var current: (url: URL, handle: FileHandle, header: GuestFileHeader, remaining: UInt64)?
    /// Folders' dates are applied at the end, since writing into a folder changes its date.
    private var folderDates = [(URL, Date)]()
    private var lastAcknowledgedBytes: UInt64 = 0

    /// - Parameters:
    ///   - rootURL: The folder that the transfer's items are written into, which must exist.
    ///   - topLevelName: The name to give each top-level item, given the name it was sent with.
    public init(rootURL: URL, topLevelName: @escaping (String) -> String = { $0 }) {
        self.rootURL = rootURL
        self.topLevelName = topLevelName
    }

    /// Handles a frame of the transfer. Returns the bytes to acknowledge when it's time to acknowledge them.
    public func receive(_ frame: GuestAgentFrame) throws -> UInt64? {
        guard !isComplete else { throw GuestAgentError("The transfer sent more after it ended.") }

        switch frame.kind {
        case .transferSize:
            size = try GuestTransferSize(payload: frame.payload)
            return nil
        case .fileHeader:
            try finishCurrentFile()
            try begin(try GuestFileHeader(payload: frame.payload))
            return acknowledgementIfDue(force: false)
        case .fileData:
            guard var current, UInt64(frame.payload.count) <= current.remaining else {
                throw GuestAgentError("The transfer sent more of a file than it said the file had.")
            }
            try current.handle.write(contentsOf: frame.payload)
            current.remaining -= UInt64(frame.payload.count)
            self.current = current
            writtenBytes += UInt64(frame.payload.count)
            return acknowledgementIfDue(force: false)
        case .filesEnd:
            try finishCurrentFile()
            for (url, date) in folderDates.reversed() {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
            }
            isComplete = true
            return acknowledgementIfDue(force: true)
        default:
            return nil
        }
    }

    /// Closes the file being written, such as when the transfer fails.
    public func abandon() {
        try? current?.handle.close()
        current = nil
    }

    private func acknowledgementIfDue(force: Bool) -> UInt64? {
        guard force || writtenBytes - lastAcknowledgedBytes >= GuestAgentFrame.acknowledgementInterval || (current == nil && writtenBytes > lastAcknowledgedBytes) else {
            return nil
        }
        lastAcknowledgedBytes = writtenBytes
        return writtenBytes
    }

    private func begin(_ header: GuestFileHeader) throws {
        var components = try header.validatedComponents()
        let parent = components.dropLast().joined(separator: "/")
        guard parent.isEmpty || folders.contains(parent) else {
            throw GuestAgentError("“\(header.path)” isn't inside a folder of the transfer.")
        }
        guard !folders.contains(header.path), !files.contains(header.path) else {
            throw GuestAgentError("“\(header.path)” is in the transfer twice.")
        }

        /// Paths keep the names items were sent with, and only the URLs use the top-level items' new names.
        if components.count == 1 {
            let name = topLevelName(components[0])
            topLevelNames[components[0]] = name
            components[0] = name
        } else if let name = topLevelNames[components[0]] {
            components[0] = name
        }

        let url = components.reduce(rootURL) { $0.appending(path: $1, directoryHint: .notDirectory) }
        if components.count == 1 {
            topLevelURLs.append(url)
        }

        switch header.type {
        case .folder:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            folders.insert(header.path)
            applyPermissions(header.permissions, to: url)
            if header.modificationTime != 0 {
                folderDates.append((url, Date(timeIntervalSince1970: TimeInterval(header.modificationTime))))
            }
        case .file:
            guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
                throw GuestAgentError("Couldn’t create “\(url.lastPathComponent)”.")
            }
            files.insert(header.path)
            current = (url, try FileHandle(forWritingTo: url), header, header.size)
            if header.size == 0 {
                try finishCurrentFile()
            }
        }
    }

    private func finishCurrentFile() throws {
        guard let current else { return }
        self.current = nil

        try current.handle.close()
        guard current.remaining == 0 else {
            throw GuestAgentError("The transfer ended before all of “\(current.url.lastPathComponent)” arrived.")
        }

        applyPermissions(current.header.permissions, to: current.url)
        if current.header.modificationTime != 0 {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(current.header.modificationTime))],
                ofItemAtPath: current.url.path(percentEncoded: false)
            )
        }
    }

    /// Only the permission bits are applied, and the owner can always read and write what's copied, so it can be moved and deleted.
    private func applyPermissions(_ permissions: UInt32, to url: URL) {
        guard permissions != 0 else { return }
        let mode = (permissions & 0o777) | 0o600
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path(percentEncoded: false))
    }
}

/// A name for an item that isn't taken in the folder: the name itself, or `Name 2.ext`, `Name 3.ext` and so on, as the Finder does.
public func uniqueURL(forItemNamed name: String, in folderURL: URL) -> URL {
    let candidate = folderURL.appending(path: name, directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else { return candidate }

    let pathExtension = (name as NSString).pathExtension
    let baseName = pathExtension.isEmpty ? name : (name as NSString).deletingPathExtension

    for number in 2... {
        let numbered = pathExtension.isEmpty ? "\(baseName) \(number)" : "\(baseName) \(number).\(pathExtension)"
        let url = folderURL.appending(path: numbered, directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }
    }
    return candidate
}
