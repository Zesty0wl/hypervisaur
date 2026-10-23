import Foundation

/// An edition of Windows in the installer's `install.wim` or `install.esd`, as described by `wimlib-imagex info`.
struct WindowsInstallImage: Hashable, Sendable {
    var index: Int
    var name: String
    var editionID: String
    var defaultLanguage: String

    /// Windows Setup requires a product key to install an edition without asking. These are the generic keys that
    /// Microsoft publishes for installing each edition, which is what Setup uses when "I don't have a product key"
    /// is chosen. They don't activate Windows.
    static let genericProductKeys = [
        "Professional": "VK7JG-NPHTM-C97JM-9MPGT-3V66T",
        "Core": "YTMG3-N6DKC-DKB77-7M9GH-8HVX7",
    ]

    /// Editions in order of preference.
    private static let preferredEditionIDs = ["Professional", "Core"]

    var genericProductKey: String? { Self.genericProductKeys[editionID] }

    /// The edition that's installed automatically, which is Windows Pro if the installer has it.
    static func preferred(in images: [WindowsInstallImage]) -> WindowsInstallImage? {
        for editionID in preferredEditionIDs {
            if let image = images.first(where: { $0.editionID == editionID }) {
                return image
            }
        }
        return nil
    }

    static func images(in imageURL: URL, toolchain: QEMUToolchain) async throws -> [WindowsInstallImage] {
        let output = try await HostCommand.run(toolchain.wimlibURL, ["info", imageURL.path])
        return parse(output)
    }

    static func parse(_ output: String) -> [WindowsInstallImage] {
        var images = [WindowsInstallImage]()
        var fields = [String: String]()

        func finishImage() {
            defer { fields = [:] }

            guard let index = fields["Index"].flatMap(Int.init),
                  let name = fields["Name"],
                  let editionID = fields["Edition ID"]
            else { return }

            images.append(WindowsInstallImage(index: index, name: name, editionID: editionID, defaultLanguage: fields["Default Language"] ?? "en-US"))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: ":") else { continue }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            if key == "Index" {
                finishImage()
            }

            fields[key] = value
        }

        finishImage()

        return images
    }
}
