import AppCore
import Foundation

/// What the Dock icon shows: a bar for the running conversion and a badge for the videos still waiting.
public struct DockTileState: Equatable, Sendable {
    /// Videos queued behind the running one (or all of them while the queue is paused).
    public let waitingCount: Int
    /// The running conversion's progress, 0 to 1; nil when nothing converts.
    public let progress: Double?
    /// The running video's name.
    public let runningName: String?

    public init(jobs: [Job], name: (Job) -> String) {
        var waiting = 0
        var progress: Double?
        var runningName: String?
        for job in jobs {
            switch job.state {
            case .queued: waiting += 1
            case .running(let value):
                progress = min(max(value, 0), 1)
                runningName = name(job)
            case .completed, .keptAsIs, .failed: break
            }
        }
        waitingCount = waiting
        self.progress = progress
        self.runningName = runningName
    }

    /// The badge text: the number of waiting videos; nil when none wait, so the badge goes away.
    public var badge: String? {
        switch waitingCount {
        case ..<1: nil
        case 1...999: "\(waitingCount)"
        default: "999+"
        }
    }

    public var isRunning: Bool { progress != nil }
}

/// One item of the Dock menu, which sits above the system's own items (Options, Show All Windows, Quit).
public struct DockMenuItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A line of information, never clickable.
        case status
        case pauseOrResume
        case showQueue
        case addVideos
        case separator
    }

    public let kind: Kind
    public let title: String
    public let isEnabled: Bool
}

public enum DockMenu {
    public static func items(for state: DockTileState, isPaused: Bool) -> [DockMenuItem] {
        var items: [DockMenuItem] = []
        if let line = statusLine(for: state, isPaused: isPaused) {
            items.append(DockMenuItem(kind: .status, title: line, isEnabled: false))
            items.append(DockMenuItem(kind: .separator, title: "", isEnabled: false))
        }
        items.append(
            DockMenuItem(
                kind: .pauseOrResume, title: isPaused ? "Resume Queue" : "Pause Queue",
                // Nothing to pause while the queue is empty and idle.
                isEnabled: isPaused || state.isRunning || state.waitingCount > 0))
        items.append(DockMenuItem(kind: .showQueue, title: "Show Queue", isEnabled: true))
        items.append(DockMenuItem(kind: .addVideos, title: "Add Videos…", isEnabled: true))
        return items
    }

    /// "Converting IMG_0001.MOV · 42%", "3 videos waiting" or "Queue paused · 3 videos waiting"; nil when idle.
    static func statusLine(for state: DockTileState, isPaused: Bool) -> String? {
        var parts: [String] = []
        if let name = state.runningName, let progress = state.progress {
            parts.append("Converting \(name) · \(Int((progress * 100).rounded()))%")
        } else if isPaused {
            parts.append("Queue paused")
        }
        if state.waitingCount > 0 {
            parts.append("\(ActivityText.videos(state.waitingCount)) waiting")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
