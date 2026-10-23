import Testing
@testable import VirtualCore

struct DownloadProgressTests {
    @Test func timeRemainingComesFromTheSpeed() {
        let progress = DownloadProgress(completedBytes: 1_000_000_000, totalBytes: 4_000_000_000, bytesPerSecond: 50_000_000)

        #expect(progress.fractionCompleted == 0.25)
        #expect(progress.estimatedTimeRemaining == 60)
    }

    @Test func timeRemainingNeedsTheSizeAndSpeed() {
        #expect(DownloadProgress(completedBytes: 10, totalBytes: nil, bytesPerSecond: 5).estimatedTimeRemaining == nil)
        #expect(DownloadProgress(completedBytes: 10, totalBytes: 100, bytesPerSecond: nil).estimatedTimeRemaining == nil)
        #expect(DownloadProgress(completedBytes: 10, totalBytes: nil, bytesPerSecond: 5).fractionCompleted == nil)
    }
}
