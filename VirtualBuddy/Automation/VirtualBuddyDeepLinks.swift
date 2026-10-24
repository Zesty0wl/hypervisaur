import Foundation
import URLQueryItemCoder
import DeepLinkSecurity
import OSLog
import VirtualCore

struct OpenVMParameters: Codable {
    var name: String
}

struct BootVMParameters: Codable {
    var name: String
    var options: VMSessionOptions?
}

struct StopVMParameters: Codable {
    var name: String
}

struct ScreenshotVMParameters: Codable {
    var name: String
    /// The identifier of the ``AutomationReply`` to write, with the screenshot as a PNG attachment.
    var reply: String
}

struct CloneVMParameters: Codable {
    var name: String
    /// The clone's name, which defaults to "Clone of" the original's name.
    var cloneName: String?
    /// The identifier of the ``AutomationReply`` to write once the clone is done.
    var reply: String?
}

enum DeepLinkAction  {
    case library
    case open(OpenVMParameters)
    case boot(BootVMParameters)
    case stop(StopVMParameters)
    case screenshot(ScreenshotVMParameters)
    case clone(CloneVMParameters)
}

extension DeepLinkAction {
    /// The reply that the sender is waiting for, if any. Failures are written to it instead of being shown.
    var replyID: UUID? {
        switch self {
        case .library, .open, .boot, .stop: nil
        case .screenshot(let params): UUID(uuidString: params.reply)
        case .clone(let params): params.reply.flatMap(UUID.init(uuidString:))
        }
    }
}

extension DeepLinkAction {
    init(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure("Invalid URL: failed to construct URLComponents")
        }
        guard let host = components.host else {
            throw Failure("Invalid URL: missing host")
        }

        switch host {
        case "library":
            self = .library
        case "open":
            let params = try Self.decodeParameters(OpenVMParameters.self, from: components)
            self = .open(params)
        case "boot":
            let params = try Self.decodeParameters(BootVMParameters.self, from: components)
            self = .boot(params)
        case "stop":
            let params = try Self.decodeParameters(StopVMParameters.self, from: components)
            self = .stop(params)
        case "screenshot":
            let params = try Self.decodeParameters(ScreenshotVMParameters.self, from: components)
            guard UUID(uuidString: params.reply) != nil else {
                throw Failure("Invalid URL: the reply must be a UUID")
            }
            self = .screenshot(params)
        case "clone":
            let params = try Self.decodeParameters(CloneVMParameters.self, from: components)
            self = .clone(params)
        default:
            throw Failure("Unrecognized URL action \"\(host)\"")
        }
    }

    private static func decodeParameters<T>(_ type: T.Type, from components: URLComponents) throws -> T where T: Decodable {
        let items = components.queryItems ?? []
        return try URLQueryItemDecoder.deepLink.decode(type, from: items)
    }
}

private extension URLQueryItemDecoder {
    static let deepLink = URLQueryItemDecoder()
}
