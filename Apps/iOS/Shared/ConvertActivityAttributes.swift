import ActivityKit
import Foundation

/// Live Activity attributes describing whole-queue conversion progress across the app and Widgets targets.
struct ConvertActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Status: String, Codable, Hashable, Sendable {
            case running
            /// A video is being fetched (downloaded from iCloud, or waiting its turn to be): the run is under way.
            case downloading
            case waitingThermal
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
        /// Current queue status (running, downloading, waiting on heat, or finished).
        var status: Status
        /// What the run is doing now, ready to show: "Downloading from iCloud · 42%", "Converting · 63%".
        var detail: String = ""
        /// The battery is low: a warning on a running activity, never a pause.
        var lowBattery: Bool = false
    }
}

/// The words of the Live Activity, tool-neutral ("Converting", not the name of a tool's action), shared by the app
/// and the widget so a state reads the same wherever it is shown.
enum LiveActivityText {
    static func title(for state: ConvertActivityAttributes.ContentState) -> String {
        switch state.status {
        case .running, .downloading:
            state.totalItems == 1 ? "Converting 1 Video" : "Converting \(state.totalItems) Videos"
        case .waitingThermal: "Paused to Cool Down"
        case .finished: "Finished Converting"
        }
    }

    static func subtitle(for state: ConvertActivityAttributes.ContentState) -> String {
        switch state.status {
        case .running, .downloading:
            if state.lowBattery { "Battery is low. Converting uses more power." } else { state.detail.isEmpty ? "Converting" : state.detail }
        case .waitingThermal: "Waiting for device temperature to drop"
        case .finished: "All videos converted"
        }
    }
}
