import Foundation

public extension VBVirtualMachine {
    /// The virtual machines in the library, read from its folder, for programs other than the app such as `vbmcp` and `hvctl`.
    static func libraryMachines(in libraryURL: URL = VBSettings.current.libraryURL) throws -> [VBVirtualMachine] {
        guard libraryURL.isReadableDirectory else { return [] }

        return try FileManager.default.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == bundleExtension }
            .compactMap { try? VBVirtualMachine(bundleURL: $0, createIfNeeded: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func libraryMachine(named name: String, in libraryURL: URL = VBSettings.current.libraryURL) throws -> VBVirtualMachine {
        guard let model = try libraryMachines(in: libraryURL).first(where: { $0.name == name }) else {
            throw Failure("There’s no virtual machine named “\(name)” in the library at \(libraryURL.path).")
        }
        return model
    }
}
