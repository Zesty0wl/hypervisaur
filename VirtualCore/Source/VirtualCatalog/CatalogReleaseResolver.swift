import Foundation
import BuddyFoundation
import OSLog

private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "CatalogReleaseResolver")

/// Finds the newest image of a release in the lists named by its ``CatalogReleaseSource``.
public struct CatalogReleaseResolver: Sendable {
    /// Lists of checksums and releases are a few kilobytes, so anything much larger isn't one.
    static let maximumIndexSize = 4 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The URL of the newest image of the release that's available to download.
    public func resolve(_ source: CatalogReleaseSource) async throws -> URL {
        let pattern = try Regex(source.fileNamePattern)

        for index in source.indexes {
            let images: [URL]
            do {
                images = Self.images(in: try await contents(of: index), listedAt: index, matching: pattern)
            } catch {
                logger.error("Couldn't read \(index.absoluteString, privacy: .public): \(error, privacy: .public)")
                continue
            }

            /// Lists sometimes still name images that have been removed, so the newest one that's there is used.
            for image in images {
                if await isAvailable(image) {
                    logger.debug("Newest image listed in \(index.absoluteString, privacy: .public) is \(image.absoluteString, privacy: .public)")
                    return image
                }
                logger.warning("\(image.absoluteString, privacy: .public) is listed but can't be downloaded")
            }
        }

        throw Failure("Couldn’t find the newest image of this release.")
    }

    /// The images in a list, newest first. A list names each image by its file name relative to the list, as a
    /// `SHA256SUMS` file or a directory listing does, or by its URL, as Fedora's `releases.json` does.
    static func images(in text: String, listedAt index: URL, matching pattern: Regex<AnyRegexOutput>) -> [URL] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>()[]{},=*"))

        let images = text.components(separatedBy: separators).compactMap { token -> URL? in
            guard !token.isEmpty,
                  let url = URL(string: token, relativeTo: index)?.absoluteURL,
                  url.scheme == "https",
                  url.lastPathComponent.wholeMatch(of: pattern) != nil
            else { return nil }
            return url
        }

        return Set(images).sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
    }

    private func contents(of index: URL) async throws -> String {
        let request = URLRequest(url: index, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await session.data(for: request)

        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw Failure("The server responded with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        guard data.count <= Self.maximumIndexSize else {
            throw Failure("The list is \(data.count) bytes, which is too large.")
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func isAvailable(_ image: URL) async -> Bool {
        var request = URLRequest(url: image, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"

        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { 200..<300 ~= $0.statusCode } ?? false
    }
}

public extension CatalogReleaseSource {
    /// Whether a file is one of the release's images, such as one downloaded earlier.
    func matches(fileName: String) -> Bool {
        guard let pattern = try? Regex(fileNamePattern) else {
            logger.fault("Invalid file name pattern \(fileNamePattern, privacy: .public)")
            return false
        }
        return fileName.wholeMatch(of: pattern) != nil
    }
}
