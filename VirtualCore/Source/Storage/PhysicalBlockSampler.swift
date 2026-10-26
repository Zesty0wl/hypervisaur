import Foundation
import Darwin

/// Finds files that share data on an APFS volume, even after both of them have changed.
///
/// APFS only identifies a file's clones while their data is identical. Once either of them changes, all that's left is the
/// size of what each still shares, not which file it's shared with. Clones keep their data at the same offsets and on the
/// same blocks of the volume, though, so where a file's data is on the volume is sampled at fixed offsets, the same for
/// every file, and files whose samples land on the same blocks share data.
enum PhysicalBlockSampler {
    /// The distance between samples. A disk image of 64 GB is sampled 1,024 times, which takes a few milliseconds.
    static let stride: Int64 = 64 << 20
    static let maximumSampleCount = 4096

    /// Where the file's data is on its volume, at each of the offsets that are sampled and have data. Parts of a disk image
    /// that have never been written to don't take up any space, and aren't included.
    static func samples(of url: URL) -> Set<Int64> {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return [] }

        var samples = Set<Int64>()
        var offset: Int64 = 0
        var count = 0

        while offset < info.st_size, count < maximumSampleCount {
            var location = log2phys()
            location.l2p_contigbytes = 4096
            location.l2p_devoffset = offset

            /// The location of a part that has no data is reported as -1.
            if fcntl(descriptor, F_LOG2PHYS_EXT, &location) == 0, location.l2p_devoffset >= 0 {
                samples.insert(location.l2p_devoffset)
            }

            offset += stride
            count += 1
        }

        return samples
    }

    /// Whether two sets of samples show that their files share a meaningful amount of data, rather than a block by chance.
    static func indicateSharing(_ a: Set<Int64>, _ b: Set<Int64>) -> Bool {
        let shared = a.intersection(b).count
        return shared >= 3 && shared * 10 >= min(a.count, b.count)
    }
}
