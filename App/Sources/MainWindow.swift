import AppKit
import QuickRunService
import SwiftUI

/// The main window, owned by AppKit: one window for the life of the process. Closing it only orders it out, so
/// the app can decide at launch whether to show it, and an open event never makes a second one.
@MainActor
final class MainWindowController {
    let window: NSWindow

    init(model: AppModel) {
        let hosting = NSHostingController(
            rootView: RootView(model: model).frame(minWidth: 900, minHeight: 600))
        // The window's size is its own (autosaved), not the content's ideal size.
        hosting.sizingOptions = []
        // The SwiftUI toolbar, search field, inspector button and navigation title belong to the real window.
        hosting.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = AppModel.displayName
        window.isReleasedWhenClosed = false
        // As in Apple's apps: green button and View > Enter Full Screen work; one window, so no tab bar.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        // Overrides the default size and position when a saved frame exists.
        window.setFrameAutosaveName("main")
        self.window = window
        model.mainWindow = window
    }
}

extension AppModel {
    /// On screen: shown, not minimized to the Dock, and the app isn't hidden.
    var isMainWindowVisible: Bool {
        guard let mainWindow else { return false }
        return WindowVisibility.isOnScreen(
            isWindowVisible: mainWindow.isVisible, isMiniaturized: mainWindow.isMiniaturized,
            isAppHidden: NSApp.isHidden)
    }

    /// Brings the main window to the front, showing it first when it was closed, minimized or the app hidden.
    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate()
        guard let window = mainWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
