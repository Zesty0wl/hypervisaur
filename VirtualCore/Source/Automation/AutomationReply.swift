import Foundation

/// The result of a request that another process, such as `vbmcp`, sends to the app through its URL scheme.
///
/// URL scheme requests can't return anything, so a request that needs a result names a reply, which the app writes to a file
/// that the sender waits for. A reply can come with an attachment, such as a screenshot, which is written before the reply.
public struct AutomationReply: Codable, Sendable {
    /// What happened, if the request succeeded.
    public var message: String?
    /// Why the request failed.
    public var error: String?

    public static func success(_ message: String) -> AutomationReply {
        AutomationReply(message: message, error: nil)
    }

    public static func failure(_ error: Error) -> AutomationReply {
        AutomationReply(message: nil, error: error.localizedDescription)
    }

    /// Where replies are written. Both the app and the processes that send it requests run as the same user.
    public static var directoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.neiljohn.hypervisaur/Automation Replies", directoryHint: .isDirectory)
    }

    /// The file for a reply. Replies are named by an identifier, so that a request can't name any other file.
    public static func url(for id: UUID) -> URL {
        directoryURL.appending(path: "\(id.uuidString).json")
    }

    public static func attachmentURL(for id: UUID, pathExtension: String) -> URL {
        directoryURL.appending(path: "\(id.uuidString).\(pathExtension)")
    }

    /// Writes the reply all at once, so that the sender never reads part of it.
    public func write(for id: UUID) throws {
        try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(for: id), options: .atomic)
    }

    /// Waits for the reply to a request and removes it.
    ///
    /// - Throws: The reply's error if the request failed, or a timeout if there's no reply in time.
    public static func wait(for id: UUID, timeout: Duration, timeoutMessage: String) async throws -> AutomationReply {
        let url = url(for: id)
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: url) {
                try? FileManager.default.removeItem(at: url)

                let reply = try JSONDecoder().decode(AutomationReply.self, from: data)
                if let error = reply.error {
                    throw Failure(error)
                }
                return reply
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        throw Failure(timeoutMessage)
    }
}
