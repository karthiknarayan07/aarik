import AppCore
import AppKit
import AppUI
import ConvertUI
import QuickRunService
import SwiftUI

/// The window's content: the shell, with the sidebar's visibility kept for the View menu.
private struct MainWindowContent: View {
    @Bindable var shell: MacShell

    var body: some View {
        MacRootView(module: shell.scene, sidebarVisibility: $shell.sidebarVisibility)
    }
}

/// The main window, owned by AppKit: one window for the life of the process. Closing it only orders it out, so
/// the app can decide at launch whether to show it, and an open event never makes a second one.
@MainActor
final class MainWindowController {
    let window: NSWindow

    init(shell: MacShell) {
        let hosting = MainWindowLayout.makeHostingController(rootView: MainWindowContent(shell: shell))
        let window = NSWindow(contentViewController: hosting)
        window.title = AppInfo.displayName
        window.isReleasedWhenClosed = false
        // As in Apple's apps: green button and View > Enter Full Screen work; one window, so no tab bar.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        MainWindowLayout.configure(window)
        window.center()
        // Overrides the default size and position when a saved frame exists.
        window.setFrameAutosaveName("main")
        self.window = window
        shell.mainWindow = window
    }
}

extension MacShell {
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
