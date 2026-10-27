import Foundation
import BuddyFoundation
import Virtualization
import OSLog
import os

private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "MacReleaseFinder")

/// Finds versions of macOS that aren't in the software catalog yet, so they can be installed as soon as Apple releases them.
///
/// AppleDB lists every build of macOS, including betas and release candidates, along with whether Apple still signs it for
/// virtual machines. Apple's own list only has its newest release, but has it the moment it's out.
public struct MacReleaseFinder: Sendable {
    private let session: URLSession
    private let cacheDirectoryURL: URL

    public init(session: URLSession = .shared, cacheDirectoryURL: URL = Self.defaultCacheDirectoryURL) {
        self.session = session
        self.cacheDirectoryURL = cacheDirectoryURL
    }

    public static var defaultCacheDirectoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "Hypervisaur", directoryHint: .isDirectory)
            .appending(path: "MacReleases", directoryHint: .isDirectory)
    }

    /// Restore images are only downloaded from Apple.
    static func isApple(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com")
    }

    /// The catalog with the releases that it doesn't have yet. Sources that can't be reached are skipped.
    /// - Parameter revalidate: Whether to ask servers between here and AppleDB for the newest list, rather than one they've kept.
    public func catalog(byAddingReleasesTo catalog: SoftwareCatalog, revalidate: Bool) async -> SoftwareCatalog {
        async let listedReleases = appleDBReleases(revalidate: revalidate)
        async let latestRelease = Self.value(within: .seconds(20)) { await latestAppleRelease() }

        var releases = await listedReleases
        if let latest = await latestRelease ?? nil, !releases.contains(where: { $0.build == latest.build }) {
            logger.info("Apple has released \(latest.name, privacy: .public) (\(latest.build, privacy: .public)), which AppleDB doesn't list yet")
            releases.append(latest)
        }

        let missing = catalog.releasesMissing(from: releases)
        guard !missing.isEmpty else { return catalog.adding(releases, mobileDeviceMinVersions: [:]) }

        logger.info("Adding \(missing.count, privacy: .public) releases that aren't in the catalog: \(missing.map(\.build).joined(separator: ", "), privacy: .public)")

        return catalog.adding(releases, mobileDeviceMinVersions: await mobileDeviceMinVersions(for: missing))
    }

    // MARK: - AppleDB

    /// AppleDB's list is about 50 MB, or 5 MB compressed.
    static let maximumAppleDBListSize = 256 * 1024 * 1024

    private struct AppleDBCache: Codable {
        var entityTag: String?
        var lastModified: String?
        var releases: [MacRestoreImageRelease]
    }

    private var appleDBCacheURL: URL { cacheDirectoryURL.appending(path: "AppleDB.json") }

    /// The list is only downloaded again when it's changed, which the server says by its entity tag.
    private func appleDBReleases(revalidate: Bool) async -> [MacRestoreImageRelease] {
        let cache = try? JSONDecoder().decode(AppleDBCache.self, from: Data(contentsOf: appleDBCacheURL))

        var request = URLRequest(url: AppleDBMacReleases.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let cache {
            if let entityTag = cache.entityTag { request.setValue(entityTag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified = cache.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        }
        if revalidate {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

        do {
            let (data, urlResponse) = try await session.data(for: request)
            let response = try (urlResponse as? HTTPURLResponse).require("AppleDB didn’t respond over HTTP.")

            if response.statusCode == 304, let cache {
                logger.debug("AppleDB's list hasn't changed")
                return cache.releases
            }
            guard response.statusCode == 200 else {
                throw Failure("AppleDB responded with HTTP \(response.statusCode).")
            }
            guard data.count <= Self.maximumAppleDBListSize else {
                throw Failure("AppleDB's list is \(data.count) bytes, which is too large.")
            }

            let releases = try AppleDBMacReleases.releases(from: data)
            logger.debug("AppleDB lists \(releases.count, privacy: .public) restore images for virtual machines")

            let newCache = AppleDBCache(
                entityTag: response.value(forHTTPHeaderField: "ETag"),
                lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                releases: releases
            )
            do {
                try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
                try JSONEncoder().encode(newCache).write(to: appleDBCacheURL, options: .atomic)
            } catch {
                logger.error("Couldn't save AppleDB's list: \(error, privacy: .public)")
            }

            return releases
        } catch {
            logger.error("Couldn't read AppleDB's list: \(error, privacy: .public)")
            return cache?.releases ?? []
        }
    }

    // MARK: - Apple

    private func latestAppleRelease() async -> MacRestoreImageRelease? {
        do {
            let image = try await VZMacOSRestoreImage.latestSupported
            let url = image.url
            let build = image.buildVersion
            let version = image.operatingSystemVersion

            guard Self.isApple(url) else {
                throw Failure("The newest restore image is at \(url.absoluteString), which isn't one of Apple's servers.")
            }

            return MacRestoreImageRelease(
                build: build,
                versionString: version.patchVersion == 0
                    ? "\(version.majorVersion).\(version.minorVersion)"
                    : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                kind: .release,
                url: url,
                downloadSize: await downloadSize(of: url),
                marketingName: nil
            )
        } catch {
            logger.error("Couldn't find Apple's newest release: \(error, privacy: .public)")
            return nil
        }
    }

    private func downloadSize(of url: URL) async -> UInt64? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"

        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init)
    }

    /// Virtualization doesn't say how long it'll wait for Apple's list, so the catalog doesn't wait for it any longer than this.
    private static func value<T: Sendable>(within timeout: Duration, of operation: @escaping @Sendable () async -> T) async -> T? {
        let continuation = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)

        return await withCheckedContinuation { newContinuation in
            continuation.withLock { $0 = newContinuation }

            Task {
                let value = await operation()
                continuation.withLock { $0.take() }?.resume(returning: value)
            }
            Task {
                try? await Task.sleep(for: timeout)
                continuation.withLock { $0.take() }?.resume(returning: nil)
            }
        }
    }

    // MARK: - Build Manifests

    /// Build manifests are about 30 MB.
    static let maximumBuildManifestSize = 128 * 1024 * 1024

    /// Reading a build manifest takes a few seconds, so a few are read at a time.
    static let maximumConcurrentBuildManifestReads = 4

    private struct BuildManifestCache: Codable {
        var mobileDeviceMinVersion: SoftwareVersion
    }

    /// The version of the MobileDevice framework that each build needs, which is in its build manifest.
    /// A build manifest doesn't change, so it's only read once.
    private func mobileDeviceMinVersions(for releases: [MacRestoreImageRelease]) async -> [String: SoftwareVersion] {
        await withTaskGroup(of: (String, SoftwareVersion?).self) { group in
            var pending = releases.makeIterator()
            var versions = [String: SoftwareVersion]()

            for _ in 0..<Self.maximumConcurrentBuildManifestReads {
                guard let release = pending.next() else { break }
                group.addTask { (release.build, await mobileDeviceMinVersion(for: release)) }
            }

            for await (build, version) in group {
                versions[build] = version
                if let release = pending.next() {
                    group.addTask { (release.build, await mobileDeviceMinVersion(for: release)) }
                }
            }

            return versions
        }
    }

    private func mobileDeviceMinVersion(for release: MacRestoreImageRelease) async -> SoftwareVersion? {
        let cacheURL = cacheDirectoryURL
            .appending(path: "BuildManifests", directoryHint: .isDirectory)
            .appending(path: "\(release.build).json")

        if let cache = try? JSONDecoder().decode(BuildManifestCache.self, from: Data(contentsOf: cacheURL)) {
            return cache.mobileDeviceMinVersion
        }

        do {
            let archive = try await RemoteZipArchive(url: release.url, session: session)
            let manifest = try await archive.contents(of: "BuildManifest.plist", maximumSize: Self.maximumBuildManifestSize)
            let version = try MacBuildManifest(data: manifest).mobileDeviceMinVersion

            logger.debug("\(release.build, privacy: .public) needs MobileDevice \(version, privacy: .public)")

            do {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(BuildManifestCache(mobileDeviceMinVersion: version)).write(to: cacheURL, options: .atomic)
            } catch {
                logger.error("Couldn't save what \(release.build, privacy: .public) needs: \(error, privacy: .public)")
            }

            return version
        } catch {
            logger.error("Couldn't read the build manifest of \(release.build, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}

/// The parts of a restore image's build manifest that the catalog needs.
struct MacBuildManifest: Decodable {
    private struct Identity: Decodable {
        struct Info: Decodable {
            var deviceClass: String?
            var mobileDeviceMinVersion: SoftwareVersion?
            var virtualMachineMinHostOS: String?

            enum CodingKeys: String, CodingKey {
                case deviceClass = "DeviceClass"
                case mobileDeviceMinVersion = "MobileDeviceMinVersion"
                case virtualMachineMinHostOS = "VirtualMachineMinHostOS"
            }
        }
        var info: Info

        enum CodingKeys: String, CodingKey {
            case info = "Info"
        }

        var isVirtualMachine: Bool {
            info.virtualMachineMinHostOS != nil || info.deviceClass?.caseInsensitiveCompare("vma2macosap") == .orderedSame
        }
    }

    private var buildIdentities: [Identity]

    private enum CodingKeys: String, CodingKey {
        case buildIdentities = "BuildIdentities"
    }

    init(data: Data) throws {
        self = try PropertyListDecoder().decode(Self.self, from: data)
    }

    /// The version of the MobileDevice framework that installing the build in a virtual machine needs.
    var mobileDeviceMinVersion: SoftwareVersion {
        get throws {
            let version = buildIdentities.first(where: \.isVirtualMachine)?.info.mobileDeviceMinVersion
            return try version.require("The build manifest doesn’t say what installing it in a virtual machine needs.")
        }
    }
}
