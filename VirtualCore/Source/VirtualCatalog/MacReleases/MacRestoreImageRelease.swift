import Foundation
import BuddyFoundation

/// A build of macOS that has a restore image for virtual machines, as listed by Apple or AppleDB.
public struct MacRestoreImageRelease: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case release
        /// A release candidate, numbered when there's more than one.
        case releaseCandidate(Int?)
        /// A developer beta, numbered from 1.
        case beta(Int)

        public var isPrerelease: Bool { self != .release }
    }

    public var build: String
    /// The version as Apple writes it, such as `27.0` or `27.0.1`.
    public var versionString: String
    public var kind: Kind
    public var url: URL
    public var downloadSize: UInt64?
    /// The name of the version of macOS, such as `Golden Gate`, when it's known.
    public var marketingName: String?

    public init(build: String, versionString: String, kind: Kind, url: URL, downloadSize: UInt64?, marketingName: String?) {
        self.build = build
        self.versionString = versionString
        self.kind = kind
        self.url = url
        self.downloadSize = downloadSize
        self.marketingName = marketingName
    }

    public var version: SoftwareVersion { SoftwareVersion(string: versionString) ?? .empty }

    /// The name shown in the list, which is written the same way as the names in the software catalog.
    public var name: String {
        switch kind {
        case .release: "macOS \(versionString)"
        case .releaseCandidate(nil): "macOS \(versionString) RC"
        case .releaseCandidate(let number?): "macOS \(versionString) RC \(number)"
        case .beta(let number): "macOS \(versionString) Developer Beta \(number)"
        }
    }

    /// The version and build of a release are what make it newer than another.
    /// Within a version, betas come first, then release candidates and the release, whose builds are in order.
    public func isNewer(than other: MacRestoreImageRelease) -> Bool {
        Self.isBuild(build, version: version, newerThan: other.build, version: other.version)
    }

    static func isBuild(_ build: String, version: SoftwareVersion, newerThan otherBuild: String, version otherVersion: SoftwareVersion) -> Bool {
        guard version == otherVersion else { return version > otherVersion }

        /// Beta builds end in a letter, such as `26B5112a`, and come before release candidates and releases such as `26B118`.
        let isBeta = build.last?.isLowercase == true
        let isOtherBeta = otherBuild.last?.isLowercase == true
        guard isBeta == isOtherBeta else { return !isBeta }

        return build.compare(otherBuild, options: .numeric) == .orderedDescending
    }
}

// MARK: - AppleDB

/// Reads the list of macOS builds that AppleDB publishes at https://api.appledb.dev/ios/macOS/main.json.
enum AppleDBMacReleases {
    static let url = URL(string: "https://api.appledb.dev/ios/macOS/main.json")!

    /// The device that macOS virtual machines identify themselves as.
    static let virtualMachineDevice = "VirtualMac2,1"

    /// The builds that have a restore image for virtual machines that Apple still signs, so they can be installed, newest first.
    /// When AppleDB lists a build more than once, such as when the release candidate is the release, it's listed as the release.
    static func releases(from data: Data) throws -> [MacRestoreImageRelease] {
        let entries = try JSONDecoder().decode([Lossy<Entry>].self, from: data).compactMap(\.value)

        var releases = [String: MacRestoreImageRelease]()
        for entry in entries {
            guard let release = entry.release else { continue }

            if let existing = releases[release.build], existing.kind.rank >= release.kind.rank { continue }
            releases[release.build] = release
        }

        return releases.values.sorted { $0.isNewer(than: $1) }
    }

    private struct Entry: Decodable {
        struct Source: Decodable {
            struct Link: Decodable {
                var url: URL
                var preferred: Bool?
                var active: Bool?
            }
            var type: String
            var deviceMap: [String]?
            var links: [Link]?
            var size: UInt64?
        }
        struct WebImage: Decodable {
            var id: String?
        }

        var osStr: String
        var version: String
        var build: String
        var signed: [String]?
        var sources: [Source]?
        var appledbWebImage: WebImage?

        var release: MacRestoreImageRelease? {
            guard osStr == "macOS",
                  build.wholeMatch(of: String.appleOSBuildRegex) != nil,
                  signed?.contains(AppleDBMacReleases.virtualMachineDevice) == true,
                  let (versionString, kind) = AppleDBMacReleases.parse(version),
                  let source = sources?.first(where: { $0.type == "ipsw" && $0.deviceMap?.contains(AppleDBMacReleases.virtualMachineDevice) == true })
            else { return nil }

            let links = (source.links ?? []).filter { MacReleaseFinder.isApple($0.url) && $0.active != false }
            guard let link = links.first(where: { $0.preferred == true }) ?? links.first else { return nil }

            return MacRestoreImageRelease(
                build: build,
                versionString: versionString,
                kind: kind,
                url: link.url,
                downloadSize: source.size,
                marketingName: appledbWebImage?.id
            )
        }
    }

    /// AppleDB writes versions like `27.2`, `27.2 RC`, `12.6.1 RC 4`, `27.2 beta` and `27.2 beta 3`.
    /// Others, such as SDKs and Background Security Improvements, aren't restore images and are left out.
    static func parse(_ version: String) -> (versionString: String, kind: MacRestoreImageRelease.Kind)? {
        guard let match = version.wholeMatch(of: #/(\d+(?:\.\d+){1,2})(?: (beta|RC)(?: (\d+))?)?/#) else { return nil }

        let versionString = String(match.1)
        let number = match.3.flatMap { Int($0) }

        switch match.2.map(String.init) {
        case nil:
            guard number == nil else { return nil }
            return (versionString, .release)
        case "RC"?:
            return (versionString, .releaseCandidate(number))
        default:
            return (versionString, .beta(number ?? 1))
        }
    }

    /// Decodes an element of a list without failing the whole list, as AppleDB lists all sorts of things.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

private extension MacRestoreImageRelease.Kind {
    /// When a build is listed more than once, it's the release, then a release candidate, then a beta.
    var rank: Int {
        switch self {
        case .release: 2
        case .releaseCandidate: 1
        case .beta: 0
        }
    }
}
