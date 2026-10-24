import AppKit
import UniformTypeIdentifiers
import VirtualCore
import VirtualWormhole

/// A virtual machine's display, whose guest pointer can be moved directly, which dragging files out of the guest needs.
@MainActor
protocol GuestPointerDriving: NSView {
    /// Moves the guest's pointer to a point in the view, with its left button held.
    func dragGuestPointer(to point: NSPoint)
    /// Releases the guest's left button at a point in the view.
    func releaseGuestPointer(at point: NSPoint)
}

/// Lets a virtual machine's display take files dropped on it from the Mac, and drag files out of the guest to the Mac.
/// The display forwards its dragging destination calls and mouse events to it.
///
/// Dragging out works by noticing when the pointer leaves the display while its button is held. That may be a drag in the
/// guest, so the guest's agent is asked to catch it with a window under the guest's pointer. If it's a drag of files, the
/// guest's button is released over that window, which refuses the drop, and a drag of the same files starts on the Mac.
/// They're copied from the guest when they're dropped.
@MainActor
final class GuestFileDragAndDrop: NSObject, NSDraggingSource {
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    weak var center: GuestFileTransferCenter?
    private weak var view: (NSView & GuestPointerDriving)?

    init(view: NSView & GuestPointerDriving) {
        self.view = view
    }

    // MARK: Dropping files on the display

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(for: sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(for: sender)
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        center?.dropTarget = nil
    }

    func draggingEnded(_ sender: NSDraggingInfo) {
        center?.dropTarget = nil
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let center, !isOwnDrag(sender), case .available = center.dropAvailability else { return false }

        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return false }

        center.dropTarget = nil
        center.put(urls)
        return true
    }

    private func updateDropTarget(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let center, !isOwnDrag(sender), !fileURLs(in: sender).isEmpty else {
            center?.dropTarget = nil
            return []
        }

        let availability = center.dropAvailability
        if center.dropTarget != availability {
            center.dropTarget = availability
        }
        if case .available = availability { return .copy }
        return []
    }

    /// Files dragged out of the guest pass over its display on their way out, and aren't dropped back on it.
    private func isOwnDrag(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as AnyObject?) === self
    }

    private func fileURLs(in sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    // MARK: Dragging files out of the guest

    private enum DragOutState {
        case idle
        /// The button was pressed in the display and hasn't left it yet.
        case pressed
        /// The pointer left the display, and the agent is finding out what's being dragged.
        case catching
        /// Files are being dragged, and the drag on the Mac starts with the next movement.
        case ready([GuestDragItem])
        /// Nothing can be dragged out, so the pointer goes to the guest as usual until the button is released.
        case passing
        case dragging
    }

    private var state = DragOutState.idle
    private var lastInsidePoint = NSPoint.zero
    private var edgePoint = NSPoint.zero
    private var nudgeOffset: CGFloat = 1
    private var catchTask: Task<Void, Never>?

    func mouseDown(with event: NSEvent) {
        catchTask?.cancel()
        catchTask = nil
        state = .pressed
        if let view {
            lastInsidePoint = view.convert(event.locationInWindow, from: nil)
        }
    }

    /// Returns `true` when the event shouldn't go to the guest, since a drag on the Mac is starting or has started.
    func mouseDragged(with event: NSEvent) -> Bool {
        guard let view else { return false }
        let point = view.convert(event.locationInWindow, from: nil)

        switch state {
        case .pressed:
            if view.bounds.contains(point) {
                lastInsidePoint = point
                return false
            }
            guard let center, center.canCatchDrags else {
                state = .passing
                return false
            }

            edgePoint = NSPoint(
                x: min(max(lastInsidePoint.x, view.bounds.minX + 2), view.bounds.maxX - 2),
                y: min(max(lastInsidePoint.y, view.bounds.minY + 2), view.bounds.maxY - 2)
            )
            state = .catching
            catchTask = Task { [weak self] in
                let items = await center.catchDrag { [weak self] in self?.nudge() }
                guard !Task.isCancelled else { return }
                self?.caught(items)
            }
            return false
        case .ready(let items):
            beginDragging(items, with: event)
            return true
        case .dragging:
            return true
        case .idle, .catching, .passing:
            return false
        }
    }

    func mouseUp(with event: NSEvent) {
        catchTask?.cancel()
        catchTask = nil
        state = .idle
    }

    private func caught(_ items: [GuestDragItem]) {
        guard case .catching = state, let view else { return }
        guard !items.isEmpty else {
            state = .passing
            return
        }

        /// The guest's drag ends over the agent's window, which refuses it, so nothing changes in the guest.
        view.releaseGuestPointer(at: edgePoint)
        state = .ready(items)
    }

    /// The drag has to move over the agent's window for it to notice the drag, even when the pointer on the Mac stays still.
    private func nudge() {
        guard case .catching = state, let view else { return }
        nudgeOffset = -nudgeOffset
        view.dragGuestPointer(to: NSPoint(x: edgePoint.x + nudgeOffset, y: edgePoint.y))
    }

    private func beginDragging(_ items: [GuestDragItem], with event: NSEvent) {
        guard let view, let center else {
            state = .passing
            return
        }

        let location = view.convert(event.locationInWindow, from: nil)
        let draggingItems = items.enumerated().map { index, item in
            let delegate = GuestFilePromiseDelegate(item: item, center: center)
            let provider = NSFilePromiseProvider(fileType: item.fileType.identifier, delegate: delegate)
            /// Providers don't keep their delegates, and Finder asks for the files after the drag has ended.
            provider.userInfo = delegate

            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            let offset = CGFloat(index) * 6
            draggingItem.setDraggingFrame(
                NSRect(x: location.x - 32 + offset, y: location.y - 32 - offset, width: 64, height: 64),
                contents: NSWorkspace.shared.icon(for: item.fileType)
            )
            return draggingItem
        }

        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .stack
        state = .dragging
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        state = .idle
    }
}

/// Copies a file or folder that was dragged out of the guest when it's dropped on the Mac.
private final class GuestFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let item: GuestDragItem
    private weak var center: GuestFileTransferCenter?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(item: GuestDragItem, center: GuestFileTransferCenter) {
        self.item = item
        self.center = center
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let item = item
        Task { @MainActor [weak center] in
            guard let center else {
                completionHandler(Failure("The virtual machine’s window was closed."))
                return
            }
            do {
                try await center.copy(item, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

extension GuestDragItem {
    var fileType: UTType {
        if isFolder { return .folder }
        let pathExtension = (name as NSString).pathExtension
        return UTType(filenameExtension: pathExtension) ?? .data
    }
}
