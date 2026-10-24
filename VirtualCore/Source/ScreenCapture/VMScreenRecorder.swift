import AVFoundation
import ScreenCaptureKit
import OSLog

/// Records a virtual machine's display and sound to a QuickTime movie, with ScreenCaptureKit.
///
/// The display is captured from the part of the window that shows it, and the sound from the app, which includes
/// everything that the virtual machine plays. The movie keeps the size it started with; if the window is resized,
/// the display is scaled to fit it.
public final class VMScreenRecorder: NSObject, @unchecked Sendable {
    public let url: URL

    /// Called on the main queue if the recording stops by itself, such as when its window closes, after the movie has been finished.
    @MainActor public var onStop: ((Error?) -> Void)?

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "VMScreenRecorder")

    /// Created once the recorder can be its delegate.
    private var stream: SCStream!
    private let configuration: SCStreamConfiguration
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput

    /// Samples arrive on this queue, and everything below is only used on it.
    private let queue = DispatchQueue(label: "VMScreenRecorder", qos: .userInitiated)
    private var isSessionStarted = false
    private var isFinishing = false

    private init(url: URL, filter: SCContentFilter, region: VMCaptureRegion) throws {
        self.url = url
        configuration = SCStreamConfiguration()
        VMScreenCapture.configure(configuration, for: region, scale: CGFloat(filter.pointPixelScale))
        /// Video encoders need an even size.
        configuration.width -= configuration.width % 2
        configuration.height -= configuration.height % 2
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
        ])
        videoInput.expectsMediaDataInRealTime = true

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw Failure("Couldn’t set up the recording.")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        super.init()

        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    /// Starts recording a region of a window to a new movie file.
    public static func start(capturing region: VMCaptureRegion, to url: URL) async throws -> VMScreenRecorder {
        let filter = try await VMScreenCapture.contentFilter(for: region)
        let recorder = try VMScreenRecorder(url: url, filter: filter, region: region)
        try await recorder.start()
        return recorder
    }

    private func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        guard writer.startWriting() else {
            throw writer.error ?? Failure("Couldn’t start writing \(url.lastPathComponent).")
        }

        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        logger.info("Recording \(self.configuration.width)x\(self.configuration.height) to \(self.url.path, privacy: .public)")
    }

    /// Follows the display when its window is resized. The movie keeps its size, and the display is scaled to fit it.
    public func update(_ region: VMCaptureRegion) async {
        configuration.sourceRect = region.rect

        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            logger.error("Couldn't update the recorded region: \(error, privacy: .public)")
        }
    }

    /// Stops recording and finishes the movie.
    public func stop() async throws -> URL {
        do {
            try await stream.stopCapture()
        } catch {
            logger.warning("Capture didn't stop cleanly: \(error, privacy: .public)")
        }

        try await finish()
        return url
    }

    private func finish() async throws {
        let shouldFinish = queue.sync {
            guard !isFinishing else { return false }
            isFinishing = true
            return true
        }
        guard shouldFinish else { return }

        let hasFrames = queue.sync { () -> Bool in
            guard isSessionStarted else { return false }

            /// The last frame lasts until now, since frames only arrive when something changes.
            writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            videoInput.markAsFinished()
            audioInput.markAsFinished()
            return true
        }

        guard hasFrames else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw Failure("Nothing was recorded.")
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? Failure("Couldn’t finish writing \(url.lastPathComponent).")
        }

        logger.info("Finished recording \(self.url.path, privacy: .public)")
    }
}

extension VMScreenRecorder: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isFinishing, sampleBuffer.isValid, writer.status == .writing else { return }

        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }

            if !isSessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                isSessionStarted = true
            }

            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            guard isSessionStarted, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        default:
            break
        }
    }

    /// Frames that only say that nothing changed have no image.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }

        return status == .complete
    }
}

extension VMScreenRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Recording stopped: \(error, privacy: .public)")

        Task {
            let finishError: Error?
            do {
                try await finish()
                finishError = nil
            } catch {
                finishError = error
            }

            await MainActor.run {
                self.onStop?(finishError ?? error)
            }
        }
    }
}
