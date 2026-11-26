import Foundation

/// Whether quitting needs the "Stop converting and quit?" question, and what it says.
public enum QuitPolicy {
    /// How long a power-off announcement counts: a shutdown another app cancels must not silence the question for
    /// good.
    public static let powerOffWindow: TimeInterval = 30

    /// Ask only while work is under way (a job running, or waiting jobs about to start: `RelaunchGate.isBusy`) and
    /// the user, not the system, is quitting. A logout, restart or shutdown quits without asking: the running job goes
    /// back to the queue and resumes on the next launch.
    public static func needsConfirmation(jobs: [Job], isQueuePaused: Bool, isSessionEnding: Bool) -> Bool {
        guard !isSessionEnding else { return false }
        return RelaunchGate.isBusy(jobs: jobs, isQueuePaused: isQueuePaused)
    }

    /// The four-character codes of the quit Apple event's reason (`kAEQuitReason`) for a logout, restart or shutdown.
    private static let sessionEndingCodes: Set<UInt32> = [
        fourCC("logo"), fourCC("rlgo"), fourCC("rrst"), fourCC("rsdn"), fourCC("rest"), fourCC("shut"),
    ]

    /// Whether the quit reason in the quit Apple event means the session is ending. A plain quit ('quia'), no reason
    /// and unknown codes are the user's own quit.
    public static func isSessionEnding(quitReason: UInt32?) -> Bool {
        quitReason.map(sessionEndingCodes.contains) ?? false
    }

    /// Either signal is enough: the quit reason says logout, restart or shutdown, or the system announced a power-off
    /// (`NSWorkspace.willPowerOffNotification`) within `powerOffWindow` seconds.
    public static func isSessionEnding(quitReason: UInt32?, powerOffAnnouncedAt: Date?, now: Date) -> Bool {
        if isSessionEnding(quitReason: quitReason) { return true }
        guard let announced = powerOffAnnouncedAt else { return false }
        let age = now.timeIntervalSince(announced)
        return age >= 0 && age <= powerOffWindow
    }

    /// The sentence under "Stop converting and quit?": what happens to the video and when the queue continues.
    public static func explanation(
        appName: String, queueStartsAutomatically: Bool, automaticPause: AutoPauseReason?
    ) -> String {
        let head = "The video in progress stops and no partial file is kept."
        guard queueStartsAutomatically else {
            return head + " It and the rest of the queue wait for you to resume the queue the next time you open "
                + appName + "."
        }
        switch automaticPause {
        case nil:
            return head + " It and the rest of the queue continue the next time you open \(appName)."
        case .thermal:
            return head + " It and the rest of the queue continue the next time you open \(appName), once your Mac "
                + "has cooled down."
        }
    }

    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
