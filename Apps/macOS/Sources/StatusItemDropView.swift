import AppKit
import QuickRunService

/// A transparent view laid over the status item's button. It accepts movie files dragged onto the icon and hands
/// them over; mouse clicks pass through to the button, so a click still opens the popover.
final class StatusItemDropView: NSView {
    private weak var button: NSStatusBarButton?
    private let onDrop: ([URL]) -> Void
    private var verdicts = DragVerdictCache()

    init(button: NSStatusBarButton, onDrop: @escaping ([URL]) -> Void) {
        self.button = button
        self.onDrop = onDrop
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        StatusItemHitTest.passesThrough(NSApp.currentEvent?.type) ? nil : super.hitTest(point)
    }

    /// Whether the drag in progress looks like it holds a movie. Worked out once per drag, so the many updates while
    /// the pointer moves over the icon don't repeat it: from the file names, and for a file with no usable name
    /// (no extension) from its content type, a few lookups at most.
    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        verdicts.verdict(forSession: sender.draggingSequenceNumber) {
            MovieDropFilter.mightContainMedia(MovieDropFilter.fileURLs(on: sender.draggingPasteboard))
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        verdicts.reset()
        let accepts = accepts(sender)
        button?.isHighlighted = accepts
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        button?.isHighlighted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        button?.isHighlighted = false
    }

    /// Accepts on the names alone; the files themselves are checked off the main thread before the run starts.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        button?.isHighlighted = false
        guard accepts(sender) else { return false }
        onDrop(MovieDropFilter.fileURLs(on: sender.draggingPasteboard))
        return true
    }
}
