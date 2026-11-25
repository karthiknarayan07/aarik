import AppKit

/// Two corrections to the menu bar SwiftUI builds for an AppKit-hosted window. Safe to repeat.
@MainActor
enum MenuFixups {
    static func apply() {
        guard let main = NSApp.mainMenu else { return }
        addFullScreenItem(to: main)
        removeStraySidebarItem(from: NSApp.helpMenu)
    }

    /// View → Enter Full Screen (⌃⌘F), Apple's standard item: AppKit keeps its title (Enter or Exit) and enabled
    /// state, and doesn't add a second one when an item with this action exists.
    private static func addFullScreenItem(to main: NSMenu) {
        guard let view = main.items.first(where: { $0.title == "View" })?.submenu,
            !view.items.contains(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
        else { return }
        if view.items.last?.isSeparatorItem == false { view.addItem(.separator()) }
        let item = NSMenuItem(
            title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.command, .control]
        view.addItem(item)
    }

    /// AppKit parks a hidden "Toggle Sidebar" (⌥⌘S) in the Help menu for a window with a split view. View → Hide
    /// Sidebar (⌃⌘S) is the one sidebar command, so the hidden one goes.
    private static func removeStraySidebarItem(from help: NSMenu?) {
        guard let help else { return }
        for item in help.items where item.action == NSSelectorFromString("toggleSidebar:") {
            help.removeItem(item)
        }
    }
}
