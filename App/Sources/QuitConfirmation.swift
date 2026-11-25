import AppCore
import AppKit

/// The "Stop converting and quit?" question, and the check that skips it when the system is ending the session.
@MainActor
enum QuitConfirmation {
    /// Set when the system announced a shutdown, restart or logout (the quit that follows is not the user's).
    private static var isPoweringOff = false
    private static var observer: (any NSObjectProtocol)?

    /// Starts watching for the system powering off. Safe to call more than once.
    static func watchForPowerOff() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { isPoweringOff = true }
        }
    }

    /// Whether this quit comes from a logout, restart or shutdown: the quit Apple event says why (`kAEQuitReason`).
    static var isSessionEnding: Bool {
        if isPoweringOff { return true }
        let descriptor = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        guard let descriptor else { return false }
        let code = descriptor.enumCodeValue != 0 ? descriptor.enumCodeValue : descriptor.typeCodeValue
        return QuitPolicy.isSessionEnding(quitReason: code)
    }

    /// Asks with a standard alert; "Stop and Quit" is the default button.
    static func confirmStop() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop converting and quit?"
        alert.informativeText =
            "The video in progress stops and no partial file is kept. It and the rest of the queue continue the "
            + "next time you open \(AppModel.displayName)."
        let stop = alert.addButton(withTitle: "Stop and Quit")
        stop.hasDestructiveAction = true
        stop.setAccessibilityLabel("Stop and Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.setAccessibilityLabel("Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
