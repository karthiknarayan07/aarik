import Foundation

/// Keeps a video dragged out of the grid from coming back in. When a tile is dropped on the app's own window, the
/// system may offer the copy it made for the drag (a temporary file) as a dropped file; importing that would add a
/// library item that disappears later. Two rules, either of which refuses it:
/// - a drag that started in this app is never an import (`isInternalDragActive`), and
/// - files inside the temporary directory are never an import.
public enum ImportDropGuard {
    /// The dropped files that may be imported, in order.
    public static func importable(
        _ urls: [URL], isInternalDragActive: Bool, temporaryDirectories: [URL] = defaultTemporaryDirectories
    ) -> [URL] {
        guard !isInternalDragActive else { return [] }
        let roots = temporaryDirectories.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return urls.filter { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return !roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    public static var defaultTemporaryDirectories: [URL] {
        [FileManager.default.temporaryDirectory, URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)]
    }
}

/// Whether a drag that started in the grid is in progress. The grid sets it from the drag session; the window's drop
/// reads it.
@MainActor
public enum InternalDrag {
    public static var isActive = false
}
