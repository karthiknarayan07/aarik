#if os(macOS)
    import AppKit

    @MainActor
    public final class MacFileRevealer: FileRevealer {
        public init() {}

        public func reveal(_ urls: [URL]) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        public func open(_ url: URL) {
            NSWorkspace.shared.open(url)
        }
    }
#endif
