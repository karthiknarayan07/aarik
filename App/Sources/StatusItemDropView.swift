import AppKit
import QuickRunService

/// A transparent view laid over the status item's button. It accepts movie files dragged onto the icon and hands
/// them over; mouse clicks pass through to the button, so a click still opens the popover.
final class StatusItemDropView: NSView {
    private weak var button: NSStatusBarButton?
    private let onDrop: ([URL]) -> Void

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

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !MovieDropFilter.movies(on: sender.draggingPasteboard).isEmpty
        button?.isHighlighted = accepts
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MovieDropFilter.movies(on: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        button?.isHighlighted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        button?.isHighlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        button?.isHighlighted = false
        let movies = MovieDropFilter.movies(on: sender.draggingPasteboard)
        guard !movies.isEmpty else { return false }
        onDrop(movies)
        return true
    }
}
