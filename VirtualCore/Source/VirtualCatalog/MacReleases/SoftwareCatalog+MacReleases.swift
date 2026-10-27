import Foundation
import BuddyFoundation

public extension SoftwareCatalog {
    /// The releases that aren't in the catalog yet.
    func releasesMissing(from releases: [MacRestoreImageRelease]) -> [MacRestoreImageRelease] {
        let builds = Set(restoreImages.map(\.build))
        return releases.filter { !builds.contains($0.build) }
    }

    /// Adds releases that aren't in the catalog yet, and makes release candidates that turned out to be the release into releases.
    ///
    /// A new release has the requirements of the newest image of the same version of macOS, or of the same major version,
    /// because they're decided by how Hypervisaur installs each version rather than by the restore image.
    /// A new major version gets a release group with the artwork of the newest one until a version of the app has its own artwork.
    /// - Parameter mobileDeviceMinVersions: The version of the MobileDevice framework that each new build needs, from its build manifest.
    func adding(_ releases: [MacRestoreImageRelease], mobileDeviceMinVersions: [String: SoftwareVersion]) -> SoftwareCatalog {
        guard let releaseChannel = channels.first(where: { !$0.isPrerelease }),
              let prereleaseChannel = channels.first(where: \.isPrerelease)
        else { return self }

        var catalog = self

        for release in releases {
            if let index = catalog.restoreImages.firstIndex(where: { $0.build == release.build }) {
                if release.kind == .release, catalog.restoreImages[index].channel != releaseChannel.id {
                    catalog.restoreImages[index].channel = releaseChannel.id
                    catalog.restoreImages[index].name = release.name
                }
                continue
            }

            /// Requirements come from the images that were already in the catalog, rather than from ones that have just been added.
            guard let group = catalog.group(for: release),
                  let template = template(for: release, in: group)
            else { continue }

            if !catalog.groups.contains(where: { $0.id == group.id }) {
                let index = catalog.groups.firstIndex(where: { $0.majorVersion < group.majorVersion }) ?? catalog.groups.endIndex
                catalog.groups.insert(group, at: index)
            }

            let image = RestoreImage(
                id: release.build,
                group: group.id,
                channel: release.kind.isPrerelease ? prereleaseChannel.id : releaseChannel.id,
                requirements: template.requirements,
                name: release.name,
                build: release.build,
                version: release.version,
                mobileDeviceMinVersion: mobileDeviceMinVersions[release.build] ?? template.mobileDeviceMinVersion,
                url: release.url,
                downloadSize: release.downloadSize
            )

            catalog.restoreImages.insert(image, at: catalog.index(forInserting: image, in: group))
        }

        return catalog
    }
}

private extension SoftwareCatalog {
    func group(for release: MacRestoreImageRelease) -> CatalogGroup? {
        let majorVersion = SoftwareVersion(majorVersionFrom: release.version)

        if let group = groups.first(where: { $0.majorVersion == majorVersion }) {
            return group
        }

        guard let newest = groups.max(by: { $0.majorVersion < $1.majorVersion }), newest.majorVersion < majorVersion else { return nil }

        return CatalogGroup(
            id: "macos\(majorVersion.major)",
            name: "macOS \(release.marketingName ?? String(majorVersion.major))",
            majorVersion: majorVersion,
            image: newest.image,
            darkImage: newest.darkImage
        )
    }

    /// The image whose requirements a new release has. Images are listed newest first.
    func template(for release: MacRestoreImageRelease, in group: CatalogGroup) -> RestoreImage? {
        let images = restoreImages.filter { $0.group == group.id }

        if let image = images.first(where: { $0.version.major == release.version.major && $0.version.minor == release.version.minor }) ?? images.first {
            return image
        }

        /// The first release of a new major version has the requirements of the newest release before it.
        let newestGroup = groups
            .filter { $0.majorVersion < group.majorVersion }
            .max(by: { $0.majorVersion < $1.majorVersion })
        return restoreImages.first(where: { $0.group == newestGroup?.id })
    }

    /// Images are listed newest first, by release group.
    func index(forInserting image: RestoreImage, in group: CatalogGroup) -> Int {
        if let index = restoreImages.firstIndex(where: {
            $0.group == group.id && MacRestoreImageRelease.isBuild(image.build, version: image.version, newerThan: $0.build, version: $0.version)
        }) {
            return index
        }

        if let last = restoreImages.lastIndex(where: { $0.group == group.id }) {
            return last + 1
        }

        let olderGroups = Set(groups.filter { $0.majorVersion < group.majorVersion }.map(\.id))
        return restoreImages.firstIndex(where: { olderGroups.contains($0.group) }) ?? restoreImages.endIndex
    }
}
