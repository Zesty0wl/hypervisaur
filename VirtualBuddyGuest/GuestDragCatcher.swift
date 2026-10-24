import Cocoa
import VirtualWormhole

/// Finds out which files are being dragged in the guest, for dragging them out to the Mac.
///
/// It shows a small window under the pointer that takes drags of files. When a drag enters it, the files are reported, and
/// when the drag is dropped there, which Hypervisaur does by releasing the guest's mouse button, the window refuses the drop,
/// so that nothing happens to the files in the guest.
@MainActor
enum GuestDragCatcher {
    /// Waits this long for a drag of files to enter the window.
    static let timeout = Duration.seconds(3)

    /// The window stays this long at most, for the drop to arrive after the drag entered it.
    static let lifetime = Duration.seconds(10)

    static func catchDrag() async -> [GuestDragItem] {
        let window = DragCatcherWindow(centeredOn: NSEvent.mouseLocation)
        window.orderFrontRegardless()

        let items = await withCheckedContinuation { continuation in
            window.onItems = { continuation.resume(returning: $0) }

            Task { @MainActor [weak window] in
                try? await Task.sleep(for: timeout)
                window?.report([])
            }
        }

        if items.isEmpty {
            window.close()
        } else {
            Task { @MainActor [weak window] in
                try? await Task.sleep(for: lifetime)
                window?.close()
            }
        }
        return items
    }
}

private final class DragCatcherWindow: NSPanel {
    var onItems: (([GuestDragItem]) -> Void)?

    init(centeredOn point: NSPoint) {
        let size: CGFloat = 64
        super.init(
            contentRect: NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        /// Windows don't get drags where they're completely transparent, so it's nearly so.
        backgroundColor = NSColor.black.withAlphaComponent(0.01)

        let view = DragCatcherView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        view.catcher = self
        contentView = view
    }

    /// Reports the items once, the first time there's anything to say.
    func report(_ items: [GuestDragItem]) {
        guard let onItems else { return }
        self.onItems = nil
        onItems(items)
    }
}

private final class DragCatcherView: NSView {
    weak var catcher: DragCatcherWindow?
    private var hasFiles = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let urls = (objects as? [URL]) ?? []

        let items = urls.map { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return GuestDragItem(isFolder: isFolder, path: url.path(percentEncoded: false))
        }

        hasFiles = !items.isEmpty
        if hasFiles {
            catcher?.report(items)
        }
        return hasFiles ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles ? .copy : []
    }

    /// The drop is refused, so that the drag ends without changing anything in the guest.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        window?.close()
        return false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        window?.close()
    }
}
