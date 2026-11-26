import Foundation

/// Holds what arrives before launch has finished (opened files, notification responses) and hands it over once,
/// when it has.
public struct LaunchBuffer<Element: Sendable>: Sendable {
    private var pending: [Element] = []
    public private(set) var hasLaunched = false

    public init() {}

    /// What to act on now: nothing before launch finished (the elements are kept), everything after.
    public mutating func receive(_ elements: [Element]) -> [Element] {
        guard !hasLaunched else { return elements }
        pending += elements
        return []
    }

    /// Marks launch finished and returns what was kept, once; later calls return nothing.
    public mutating func launchFinished() -> [Element] {
        hasLaunched = true
        defer { pending = [] }
        return pending
    }

    /// Whether anything is waiting for launch to finish.
    public var hasPending: Bool { !pending.isEmpty }
}

/// Where files from a Dock drop or Open With go.
public enum OpenedFilesRoute: Equatable, Sendable {
    /// The window is on screen: the files join Local Files and nothing is queued.
    case addToLibrary
    /// No window on screen: a quick run.
    case quickRun

    public static func route(windowVisible: Bool) -> OpenedFilesRoute {
        windowVisible ? .addToLibrary : .quickRun
    }
}

/// Whether the main window is shown when launch finishes.
public enum LaunchWindowPlan: Equatable, Sendable {
    case show
    case stayHidden

    /// Files that arrived with the launch and nothing that needs the window (a notification response) keep it
    /// hidden: they are a quick run. Any other launch shows it.
    public static func plan(openedFileCount: Int, hasNotificationResponse: Bool) -> LaunchWindowPlan {
        openedFileCount > 0 && !hasNotificationResponse ? .stayHidden : .show
    }
}

public enum WindowVisibility {
    /// On screen: shown, not minimized to the Dock, and the app isn't hidden.
    public static func isOnScreen(isWindowVisible: Bool, isMiniaturized: Bool, isAppHidden: Bool) -> Bool {
        isWindowVisible && !isMiniaturized && !isAppHidden
    }
}

public enum NotificationPolicy {
    /// A banner is for someone who isn't looking at the result: it is skipped only when the app is active and its
    /// window is on screen (the Activity lists already show it). A windowless run always posts, even though a Dock
    /// drop made the app active.
    public static func shouldPost(appIsActive: Bool, windowOnScreen: Bool) -> Bool {
        !(appIsActive && windowOnScreen)
    }

    /// The rule for one quick run's notification. A run started from the menu bar item reports itself in the
    /// popover, so its banner is skipped only while the popover is open; any other run follows the window rule.
    public static func shouldPost(
        origin: QuickRunOrigin, appIsActive: Bool, windowOnScreen: Bool, popoverVisible: Bool
    ) -> Bool {
        switch origin {
        case .statusItem: !popoverVisible
        case .background: shouldPost(appIsActive: appIsActive, windowOnScreen: windowOnScreen)
        }
    }
}
