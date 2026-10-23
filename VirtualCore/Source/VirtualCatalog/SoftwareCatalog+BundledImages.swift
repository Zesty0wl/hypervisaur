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
