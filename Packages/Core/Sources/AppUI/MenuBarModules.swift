import AppCore
import Foundation

/// What the menu bar popover's modules say: the ring for the current job, the queue count and the pause tile.
/// Plain values, so the wording and the enabled states are tested without a view.
public struct MenuBarModules: Equatable, Sendable {
    public let ringValue: Double
    public let isRunning: Bool
    public let queueCount: Int
    public let isPaused: Bool
    let isIdle: Bool

    public init(activity: ActivitySummary, isPaused: Bool) {
        ringValue = activity.runningProgress ?? 0
        isRunning = activity.runningProgress != nil
        queueCount = activity.queue
        self.isPaused = isPaused
        isIdle = activity.isIdle
    }

    /// "Converting", "Paused" or "Idle".
    public var ringCaption: String {
        if isRunning { return "Converting" }
        return isPaused && queueCount > 0 ? "Paused" : "Idle"
    }

    /// "1 video in the queue", "3 videos in the queue", "Queue is empty".
    public var queueCaption: String {
        queueCount == 0 ? "Queue is empty" : "\(ActivityText.videos(queueCount)) in the queue"
    }

    public var pauseTitle: String { isPaused ? "Resume" : "Pause" }
    public var pauseSymbol: String { isPaused ? "play.fill" : "pause.fill" }
    /// Nothing to pause while the queue is empty, unless it is paused already (then it can be resumed).
    public var isPauseEnabled: Bool { !isIdle || isPaused }
}
