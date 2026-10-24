import Foundation
import ImageIO
import Testing
@testable import VirtualCore

final class VMCaptureTests {
    private let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "VMCaptureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func makeVirtualMachine(named name: String) throws -> VBVirtualMachine {
        try VBVirtualMachine(bundleURL: directoryURL.appending(path: "\(name).\(VBVirtualMachine.bundleExtension)"), isNewInstall: true)
    }

    private var date: Date {
        var components = DateComponents(year: 2026, month: 10, day: 23, hour: 21, minute: 5, second: 9)
        components.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func capturesAreNamedAfterTheVirtualMachineAndTime() throws {
        let model = try makeVirtualMachine(named: "Windows 11")

        let url = VMCaptureLocation.newFileURL(for: model, pathExtension: "png", date: date, in: directoryURL)

        #expect(url.lastPathComponent == "Windows 11 2026-10-23 at 21.05.09.png")
    }

    @Test func capturesDontReplaceEarlierOnes() throws {
        let model = try makeVirtualMachine(named: "Linux")
        let first = VMCaptureLocation.newFileURL(for: model, pathExtension: "mov", date: date, in: directoryURL)
        try Data().write(to: first)

        let second = VMCaptureLocation.newFileURL(for: model, pathExtension: "mov", date: date, in: directoryURL)

        #expect(second.lastPathComponent == "Linux 2026-10-23 at 21.05.09 2.mov")
    }

    @Test func screenshotsAreWrittenAsPNG() async throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = try #require(context.makeImage())
        let url = directoryURL.appending(path: "Screenshot.png")

        try await VMScreenCapture.writePNG(image, to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let written = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(written.width == 4)
        #expect(written.height == 2)
    }

    @Test func repliesAreReadOnce() async throws {
        let id = UUID()
        try AutomationReply.success("Done").write(for: id)

        let reply = try await AutomationReply.wait(for: id, timeout: .seconds(1), timeoutMessage: "No reply")

        #expect(reply.message == "Done")
        #expect(!FileManager.default.fileExists(atPath: AutomationReply.url(for: id).path))
    }

    @Test func failedRequestsThrowTheirError() async throws {
        let id = UUID()
        try AutomationReply.failure(Failure("It isn’t running.")).write(for: id)

        await #expect {
            try await AutomationReply.wait(for: id, timeout: .seconds(1), timeoutMessage: "No reply")
        } throws: { error in
            error.localizedDescription == "It isn’t running."
        }
    }

    @Test func missingRepliesTimeOut() async throws {
        await #expect {
            try await AutomationReply.wait(for: UUID(), timeout: .milliseconds(300), timeoutMessage: "No reply")
        } throws: { error in
            error.localizedDescription == "No reply"
        }
    }
}
