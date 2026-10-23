import Foundation
import Combine

public enum DownloadState: Hashable {
    case idle
    case preCheck(_ message: String)
    case downloading(_ progress: DownloadProgress?)
    case failed(_ error: String)
    case done(_ localURL: URL)
}

public struct DownloadProgress: Hashable, Sendable {
    public var completedBytes: Int64
    /// The size of the download, if the server says what it is.
    public var totalBytes: Int64?
    /// The recent download speed, once there's been enough of the download to work it out.
    public var bytesPerSecond: Double?

    public init(completedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Double?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard let totalBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(max(0, totalBytes - completedBytes)) / bytesPerSecond
    }
}

public protocol DownloadBackend: AnyObject {
    init(library: VMLibraryController, cookie: String?)
    var statePublisher: AnyPublisher<DownloadState, Never> { get }
    @MainActor func startDownload(with url: URL)
    @MainActor func cancelDownload()
}
