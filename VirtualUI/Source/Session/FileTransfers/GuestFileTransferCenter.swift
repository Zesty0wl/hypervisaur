import SwiftUI
import VirtualCore
import VirtualWormhole
import OSLog

private let logger = Logger(subsystem: VirtualUIConstants.subsystemName, category: "GuestFileTransferCenter")

/// Copies files between the Mac and a virtual machine's guest, by dropping them on its window or dragging them out of it,
/// and keeps track of the copies, which the window shows.
@MainActor
final class GuestFileTransferCenter: ObservableObject {
    @Published private(set) var transfers = [GuestFileTransfer]()

    /// Set while files from the Mac are dragged over the virtual machine's display.
    @Published var dropTarget: DropTarget?

    enum DropTarget: Equatable {
        case available
        case unavailable(String)
    }

    private weak var controller: VMController?

    init(controller: VMController) {
        self.controller = controller
    }

    private var guestName: String { controller?.virtualMachineModel.name ?? "the virtual machine" }

    private var systemType: VBGuestType? { controller?.virtualMachineModel.configuration.systemType }

    private var connection: GuestAgentConnection? { controller?.guestAgent }

    /// Whether files can be dropped on the virtual machine now, or why not.
    var dropAvailability: DropTarget {
        guard let connection, connection.info != nil else {
            return .unavailable(agentMissingMessage)
        }
        guard connection.supportsFileTransfers else {
            return .unavailable(agentOutdatedMessage)
        }
        return .available
    }

    /// Whether files dragged in the guest can be dragged out to the Mac. Linux desktops don't let the agent catch drags.
    var canCatchDrags: Bool {
        guard systemType != .linux, case .available = dropAvailability else { return false }
        return true
    }

    private var agentMissingMessage: String {
        switch systemType {
        case .windows: "Copying files needs the Hypervisaur agent, which Windows installs from the DRIVERS drive when it starts."
        case .linux: "Copying files needs the Hypervisaur agent. Install it from the HYPERVISAUR disc in Linux."
        case .mac, nil: "Copying files needs the Hypervisaur Guest app, which you can install from the Guest disk."
        }
    }

    private var agentOutdatedMessage: String {
        switch systemType {
        case .windows: "Copying files needs a newer Hypervisaur agent, which Windows installs from the DRIVERS drive when it restarts."
        case .linux: "Copying files needs a newer Hypervisaur agent, which is being installed. Try again in a moment."
        case .mac, nil: "Copying files needs a newer Hypervisaur Guest app. Open it from the Guest disk to update it."
        }
    }

    // MARK: Transfers

    /// Copies files and folders from the Mac to the guest's desktop.
    func put(_ urls: [URL]) {
        guard !urls.isEmpty, let connection else { return }

        let title = urls.count == 1
            ? "Copying “\(urls[0].lastPathComponent)” to \(guestName)"
            : "Copying \(urls.count) items to \(guestName)"

        let transfer = GuestFileTransfer(title: title, isToGuest: true, operation: GuestFileTransferOperation(.toGuest(urls), connection: connection))
        start(transfer)
    }

    /// Copies a file or folder that was dragged out of the guest to where it was dropped on the Mac.
    func copy(_ item: GuestDragItem, to destination: URL) async throws {
        guard let connection else { throw Failure("The virtual machine isn’t running.") }

        let transfer = GuestFileTransfer(
            title: "Copying “\(item.name)” from \(guestName)",
            isToGuest: false,
            operation: GuestFileTransferOperation(.fromGuest(path: item.path, destination: destination), connection: connection)
        )
        start(transfer)
        try await transfer.completion()
    }

    /// Finds out which files are being dragged in the guest. Returns nothing if no files are, or the guest can't tell.
    func catchDrag(nudge: @escaping @MainActor () -> Void) async -> [GuestDragItem] {
        guard canCatchDrags, let connection else { return [] }
        do {
            return try await GuestFileTransferOperation.catchDrag(over: connection, nudge: nudge)
        } catch {
            logger.error("Couldn't catch a drag in the guest: \(error, privacy: .public)")
            return []
        }
    }

    func dismiss(_ transfer: GuestFileTransfer) {
        withAnimation(.snappy) {
            transfers.removeAll { $0 === transfer }
        }
    }

    private func start(_ transfer: GuestFileTransfer) {
        withAnimation(.snappy) {
            transfers.append(transfer)
        }

        transfer.start { [weak self, weak transfer] in
            guard let self, let transfer else { return }

            switch transfer.state {
            case .finished:
                /// Finished copies are shown for a moment, so that it's clear they finished.
                Task { @MainActor [weak self, weak transfer] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, let transfer else { return }
                    self.dismiss(transfer)
                }
            case .cancelled:
                self.dismiss(transfer)
            case .running, .failed:
                break
            }
        }
    }
}

/// A copy of files to or from a guest, as the window shows it.
@MainActor
final class GuestFileTransfer: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case cancelled
        case failed(String)
    }

    let title: String
    let isToGuest: Bool

    @Published private(set) var completedBytes: UInt64 = 0
    @Published private(set) var totalBytes: UInt64?
    @Published private(set) var bytesPerSecond: Double?
    @Published private(set) var state = State.running

    private let operation: GuestFileTransferOperation
    private var task: Task<Void, Never>?
    private var waiters = [CheckedContinuation<Void, Error>]()
    private var lastSample: (date: ContinuousClock.Instant, bytes: UInt64)?

    init(title: String, isToGuest: Bool, operation: GuestFileTransferOperation) {
        self.title = title
        self.isToGuest = isToGuest
        self.operation = operation
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return state == .finished ? 1 : nil }
        return min(Double(completedBytes) / Double(totalBytes), 1)
    }

    /// How long the rest of the copy should take at its current speed.
    var timeRemaining: Duration? {
        guard let totalBytes, let bytesPerSecond, bytesPerSecond > 0, totalBytes > completedBytes else { return nil }
        return .seconds(Double(totalBytes - completedBytes) / bytesPerSecond)
    }

    func cancel() {
        operation.cancel()
    }

    fileprivate func start(onEnd: @escaping @MainActor () -> Void) {
        let throttle = ProgressThrottle { [weak self] progress in
            self?.update(progress)
        }

        task = Task { [operation] in
            let result: State
            do {
                try await operation.run { throttle.report($0) }
                result = .finished
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }

            throttle.flush()
            self.finish(result)
            onEnd()
        }
    }

    /// Waits until the copy ends, and throws unless it finished.
    fileprivate func completion() async throws {
        switch state {
        case .finished: return
        case .cancelled: throw CancellationError()
        case .failed(let message): throw Failure(message)
        case .running:
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }
    }

    private func finish(_ result: State) {
        state = result
        if result == .finished, let totalBytes {
            completedBytes = totalBytes
        }

        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            switch result {
            case .finished: waiter.resume()
            case .cancelled: waiter.resume(throwing: CancellationError())
            case .failed(let message): waiter.resume(throwing: Failure(message))
            case .running: break
            }
        }
    }

    /// The speed is smoothed over recent progress, so that it doesn't jump around with each acknowledgement.
    private func update(_ progress: GuestFileTransferOperation.Progress) {
        let now = ContinuousClock.now

        if let lastSample, progress.completedBytes >= lastSample.bytes {
            let elapsed = (now - lastSample.date) / .seconds(1)
            if elapsed >= 0.25 {
                let speed = Double(progress.completedBytes - lastSample.bytes) / elapsed
                bytesPerSecond = bytesPerSecond.map { $0 * 0.6 + speed * 0.4 } ?? speed
                self.lastSample = (now, progress.completedBytes)
            }
        } else {
            lastSample = (now, progress.completedBytes)
        }

        completedBytes = progress.completedBytes
        totalBytes = progress.totalBytes
    }
}

/// Passes progress to the main thread at most ten times a second, however often it's reported.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: GuestFileTransferOperation.Progress?
    private var isScheduled = false
    private let deliver: @MainActor (GuestFileTransferOperation.Progress) -> Void

    init(deliver: @escaping @MainActor (GuestFileTransferOperation.Progress) -> Void) {
        self.deliver = deliver
    }

    func report(_ progress: GuestFileTransferOperation.Progress) {
        let shouldSchedule = lock.withLock {
            latest = progress
            defer { isScheduled = true }
            return !isScheduled
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            MainActor.assumeIsolated { flush() }
        }
    }

    @MainActor
    func flush() {
        let progress = lock.withLock {
            defer { latest = nil; isScheduled = false }
            return latest
        }
        if let progress {
            deliver(progress)
        }
    }
}
