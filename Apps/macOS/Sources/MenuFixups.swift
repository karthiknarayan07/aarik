import AppKit

/// Keeps the menu bar SwiftUI builds for an AppKit-hosted window to Apple's standard shape:
/// - AppKit parks a hidden "Toggle Sidebar" (⌥⌘S) in the Help menu for a window with a split view. View → Hide
///   Sidebar (⌃⌘S) is the one sidebar command, so that item is removed from Help as soon as it is added.
/// - View gets Apple's standard Enter Full Screen (⌃⌘F). AppKit has no public API for its localized title, so the
///   title is English.
///
/// Both work from `NSMenu.didAddItemNotification`, so no timer is involved: the fixes happen when the items do.
@MainActor
final class MenuFixups {
    private static let toggleSidebar = NSSelectorFromString("toggleSidebar:")
    private var observer: (any NSObjectProtocol)?

    /// Starts observing menu changes. Call before SwiftUI builds the menus (`applicationWillFinishLaunching`).
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { notification in
            // Delivered on the main queue, so the notification never leaves the main actor.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated {
                // The whole menu is checked, not the item at the notification's index: that index can be stale
                // by the time the block runs.
                if let menu = notification.object as? NSMenu { Self.fix(menu) }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Fixes the items that were added before `start` or before the main menu existed. Call once after launch.
    func sweep() {
        if let main = NSApp.mainMenu { Self.sweep(main) }
    }

    private static func sweep(_ menu: NSMenu) {
        fix(menu)
        for item in menu.items {
            if let submenu = item.submenu { sweep(submenu) }
        }
    }

    private static func fix(_ menu: NSMenu) {
        if isHelpMenu(menu) {
            for item in menu.items where item.action == toggleSidebar { menu.removeItem(item) }
        }
        if menu.items.contains(where: isSidebarCommand) { addFullScreenItem(to: menu) }
    }

    /// `NSApp.helpMenu` when set; otherwise the menu holding the Help item (`showHelp:`), which SwiftUI may not
    /// have registered as the Help menu.
    private static func isHelpMenu(_ menu: NSMenu) -> Bool {
        if let help = NSApp.helpMenu { return menu === help }
        return menu.items.contains { $0.action == #selector(NSApplication.showHelp(_:)) }
    }

    /// Our own sidebar command, recognised by its shortcut (⌃⌘S), not by its title: it sits in the View menu.
    private static func isSidebarCommand(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.command, .control]
    }

    /// Enter Full Screen as Apple's apps have it: AppKit keeps the title (Enter or Exit) and enabled state, and
    /// doesn't add a second item when one with this action exists.
    private static func addFullScreenItem(to view: NSMenu) {
        guard !view.items.contains(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }) else { return }
        if view.items.last?.isSeparatorItem == false { view.addItem(.separator()) }
        let item = NSMenuItem(
            title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.command, .control]
        view.addItem(item)
    }
}
