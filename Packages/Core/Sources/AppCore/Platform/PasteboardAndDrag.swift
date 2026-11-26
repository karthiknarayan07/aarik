import Foundation

/// The general pasteboard. Adapter: `SystemPasteboard`. Tests use `FakePasteboard` (MediaTestSupport).
@MainActor
public protocol Pasteboarding: AnyObject {
    func copy(text: String)
    func copy(fileURLs: [URL])
}

/// What a drag out of the app carries: the file itself, so the drop target gets a copy it can read. The same on both
/// platforms; the view layer attaches it with `onDrag` or `.draggable`.
public enum DragOut {
    public static func itemProvider(for url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }
}
