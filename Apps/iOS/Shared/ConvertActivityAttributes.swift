import ActivityKit
import Foundation

/// Live Activity attributes describing whole-queue conversion progress across the app and Widgets targets.
struct ConvertActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Status: String, Codable, Hashable, Sendable {
            case running
            case waitingThermal
            case waitingBattery
            case finished
        }

        /// Jobs still queued or running.
        var itemsRemaining: Int
        /// Total jobs in the active run.
        var totalItems: Int
        /// Whole-queue fraction completed (`0...1`).
        var progress: Double
        /// Bytes freed by completed jobs in the queue.
        var savedBytes: Int64
        /// Current queue status (running, waiting on heat/battery, or finished).
        var status: Status
    }
}
