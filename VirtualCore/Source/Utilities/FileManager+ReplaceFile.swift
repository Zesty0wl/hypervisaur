import Foundation

public extension FileManager {
    /// Writes `data` to a file at `url`, replacing the file that's there if there is one.
    ///
    /// Nothing is ever deleted: if something other than a regular file is at `url`, such as a folder or a symbolic link, this
    /// throws and leaves it as it was. The data is written to a temporary file that's then renamed over the old one, so the old
    /// file is only replaced once the new one is complete, and a folder that appears at `url` in the meantime makes the rename
    /// fail rather than being replaced.
    func replaceRegularFile(at url: URL, with data: Data) throws {
        if let type = try? attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type != .typeRegular {
            throw Failure("\(url.path) already exists and isn’t a file, so it wasn’t replaced.")
        }

        try data.write(to: url, options: .atomic)
    }
}
