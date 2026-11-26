import AppCore
import AppKit

/// The "Stop converting and quit?" question, and the signals that skip it when the system is ending the session.
@MainActor
enum QuitConfirmation {
    /// When the system last announced a shutdown, restart or logout. Cleared when the app becomes active again (the
    /// power-off was cancelled), and ignored after `QuitPolicy.powerOffWindow` seconds.
    private static var powerOffAnnouncedAt: Date?
    private static var observers: [any NSObjectProtocol] = []

    /// Starts watching for the system powering off. Safe to call more than once.
    static func watchForPowerOff() {
        guard observers.isEmpty else { return }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { powerOffAnnouncedAt = Date() }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { powerOffAnnouncedAt = nil }
            })
    }

    /// Whether this quit comes from a logout, restart or shutdown: the quit Apple event says why (`kAEQuitReason`), or
    /// the system just announced a power-off.
    static var isSessionEnding: Bool {
        let descriptor = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        let code = descriptor.map { $0.enumCodeValue != 0 ? $0.enumCodeValue : $0.typeCodeValue }
        return QuitPolicy.isSessionEnding(quitReason: code, powerOffAnnouncedAt: powerOffAnnouncedAt, now: Date())
    }

    /// Asks with a standard alert; "Stop and Quit" is the default button.
    static func confirmStop(queueStartsAutomatically: Bool, automaticPause: AutoPauseReason?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop converting and quit?"
        alert.informativeText = QuitPolicy.explanation(
            appName: AppInfo.displayName, queueStartsAutomatically: queueStartsAutomatically,
            automaticPause: automaticPause)
        let stop = alert.addButton(withTitle: "Stop and Quit")
        stop.hasDestructiveAction = true
        stop.setAccessibilityLabel("Stop and Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.setAccessibilityLabel("Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
