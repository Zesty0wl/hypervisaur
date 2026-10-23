import Foundation

extension SoftwareCatalog {
    /// The built-in catalog refers to its artwork on VirtualBuddy's server, which Hypervisaur doesn't use.
    /// The same images are bundled with the app under the same file names, so the catalog refers to those instead.
    func usingBundledImages(in directoryURL: URL) -> SoftwareCatalog {
        var catalog = self
        catalog.groups = groups.map { group in
            var group = group
            group.image = group.image.usingBundledImage(in: directoryURL)
            group.darkImage = group.darkImage?.usingBundledImage(in: directoryURL)
            return group
        }
        return catalog
    }

    /// Where Hypervisaur's repository publishes the legacy guest apps, which are the same files that VirtualBuddy publishes.
    static let legacyGuestAppBaseURL = URL(string: "https://raw.githubusercontent.com/Zesty0wl/hypervisaur/main/data/LegacyGuestApp/")!

    /// The built-in catalog refers to the legacy guest apps in VirtualBuddy's repository. Hypervisaur's repository has
    /// the same files, which are checked against the catalog's digests after they're downloaded.
    func usingHypervisaurLegacyGuestApps() -> SoftwareCatalog {
        var catalog = self
        catalog.legacyGuestAppVersions = legacyGuestAppVersions.map { version in
            var version = version
            version.url = Self.legacyGuestAppBaseURL.appending(path: version.url.lastPathComponent)
            return version
        }
        return catalog
    }
}

private extension CatalogGraphic {
    func usingBundledImage(in directoryURL: URL) -> CatalogGraphic {
        var graphic = self
        graphic.url = url.bundledCopy(in: directoryURL)
        graphic.thumbnail.url = thumbnail.url.bundledCopy(in: directoryURL)
        return graphic
    }
}

private extension URL {
    /// The bundled image with the same file name, or the original URL if there isn't one.
    func bundledCopy(in directoryURL: URL) -> URL {
        guard !isFileURL else { return self }

        let candidate = directoryURL.appending(path: lastPathComponent)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : self
    }
}
