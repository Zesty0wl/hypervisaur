import Foundation
import Darwin

/// How much space a file takes up on its volume, and how much of that it shares with clones of it.
public struct FileStorageUsage: Hashable, Sendable {
    /// The file's size, as the Finder shows it. For a disk image, that's the capacity of the disk.
    public var logicalSize: UInt64
    /// The space the file's data takes up, including what it shares with clones. Disk images only take up the space
    /// that's been written to, so this can be much less than their size.
    public var allocatedSize: UInt64
    /// The part of ``allocatedSize`` that no other file uses, which is what deleting the file frees. On volumes that
    /// can't clone files, nothing is shared, so it's all of it.
    public var privateSize: UInt64
    /// Identifies the file's data for as long as it's identical to its clones' data. It changes as soon as either of them changes.
    public var cloneID: UInt64?
    /// How many files share the data that ``cloneID`` identifies, this one included.
    public var cloneReferenceCount: UInt32

    /// The part of ``allocatedSize`` that other files use too.
    public var sharedSize: UInt64 { allocatedSize - min(privateSize, allocatedSize) }

    public init(logicalSize: UInt64, allocatedSize: UInt64, privateSize: UInt64, cloneID: UInt64? = nil, cloneReferenceCount: UInt32 = 1) {
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.privateSize = privateSize
        self.cloneID = cloneID
        self.cloneReferenceCount = cloneReferenceCount
    }

    /// Measures a regular file, without following symbolic links.
    /// - Returns: `nil` for anything that isn't a regular file, or that can't be read.
    public static func measure(_ url: URL) -> FileStorageUsage? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }

        let allocatedSize = UInt64(max(info.st_blocks, 0)) * 512
        var usage = FileStorageUsage(logicalSize: UInt64(max(info.st_size, 0)), allocatedSize: allocatedSize, privateSize: allocatedSize)

        readCloneAttributes(of: url, into: &usage)

        return usage
    }

    /// APFS reports how much of a file's data is shared with clones. Other file systems don't return the attributes,
    /// and everything a file takes up is its own there.
    private static func readCloneAttributes(of url: URL, into usage: inout FileStorageUsage) {
        let requested = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = requested

        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(url.path, &list, bytes.baseAddress, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return }

        buffer.withUnsafeBytes { bytes in
            /// The buffer starts with its length and which attributes were returned, followed by the attributes in the order of their bits.
            var offset = MemoryLayout<UInt32>.size
            let returned = bytes.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self).forkattr
            offset += MemoryLayout<attribute_set_t>.size

            if returned & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                let privateSize = bytes.loadUnaligned(fromByteOffset: offset, as: Int64.self)
                usage.privateSize = min(UInt64(max(privateSize, 0)), usage.allocatedSize)
                offset += MemoryLayout<Int64>.size
            }
            if returned & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                usage.cloneID = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                offset += MemoryLayout<UInt64>.size
            }
            if returned & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0 {
                usage.cloneReferenceCount = max(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self), 1)
            }
        }
    }
}
