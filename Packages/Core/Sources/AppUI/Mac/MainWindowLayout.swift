#if os(macOS)
    import AppKit
    import SwiftUI

    /// How the main window is sized, in one place so a test can hold it. The window's frame belongs to the user (and its
    /// autosave); pages, toolbars and the inspector never drive it. That means no SwiftUI size reaches the window, and the
    /// minimum is the window's own.
    @MainActor
    public enum MainWindowLayout {
        /// The smallest content size: wide enough for the sidebar, a grid and the inspector.
        public static let minimumContentSize = NSSize(width: 900, height: 600)
        /// The size of a first launch, before an autosaved frame exists.
        public static let defaultContentSize = NSSize(width: 1280, height: 820)
        /// None: the hosting controller neither sets the window's size from the content's ideal size nor its minimum or
        /// maximum from the content's, so switching pages cannot move the frame.
        public static let sizingOptions: NSHostingSizingOptions = []
        public static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

        /// A hosting controller for the window's content, with no size coming from SwiftUI.
        public static func makeHostingController<Content: View>(rootView: Content) -> NSHostingController<Content> {
            let hosting = NSHostingController(rootView: rootView)
            hosting.sizingOptions = sizingOptions
            // The SwiftUI toolbar, search field, inspector button and navigation title belong to the real window.
            hosting.sceneBridgingOptions = .all
            return hosting
        }

        /// The window's own size rules. Call before the frame autosave name is set, so a saved frame wins.
        public static func configure(_ window: NSWindow) {
            window.styleMask = styleMask
            window.contentMinSize = minimumContentSize
            window.setContentSize(defaultContentSize)
        }
    }
#endif
