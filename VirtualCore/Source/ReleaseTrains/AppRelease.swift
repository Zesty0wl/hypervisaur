import Foundation
import BuddyFoundation

/// A release of Hypervisaur published on GitHub, where people download it from.
public struct AppRelease: Hashable, Sendable {
    public var version: SoftwareVersion
    public var name: String
    /// The release's page, which has its installer.
    public var pageURL: URL

    public init(version: SoftwareVersion, name: String, pageURL: URL) {
        self.version = version
        self.name = name
        self.pageURL = pageURL
    }
}

extension AppRelease: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case pageURL = "html_url"
    }

    /// Decodes a release as GitHub's REST API describes it. Releases are tagged with their version, such as `v0.2.0`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let tag = try container.decode(String.self, forKey: .tagName)
        let versionString = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let version = SoftwareVersion(string: versionString) else {
            throw DecodingError.dataCorruptedError(forKey: .tagName, in: container, debugDescription: "The tag \(tag) isn't a version number.")
        }

        let name = try container.decodeIfPresent(String.self, forKey: .name)?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.version = version
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Hypervisaur \(version)"
        self.pageURL = try container.decode(URL.self, forKey: .pageURL)
    }
}

public extension AppRelease {
    static let releasesPageURL = URL(string: "https://github.com/Zesty0wl/hypervisaur/releases")!

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Zesty0wl/hypervisaur/releases/latest")!

    /// The newest release. Drafts and pre-releases aren't included.
    static func latest(session: URLSession = .shared) async throws -> AppRelease {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure("GitHub responded with HTTP \(status).")
        }

        return try JSONDecoder().decode(AppRelease.self, from: data)
    }
}
