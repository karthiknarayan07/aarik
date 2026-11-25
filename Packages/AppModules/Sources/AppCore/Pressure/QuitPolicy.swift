import Foundation

/// Whether quitting needs the "Stop converting and quit?" question.
public enum QuitPolicy {
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

    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
