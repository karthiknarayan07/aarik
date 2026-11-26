import AppCore
import Foundation

/// What a run is doing right now, in the words the Live Activity and the system's continued-processing task show:
/// the real stage ("Downloading from iCloud · 42%", then "Converting · 63%"), not a generic "processing". Pure, so
/// the wording and the "still under way" rule are tested without ActivityKit.
struct RunStatus: Equatable {
    /// "Converting 3 Videos".
    var title: String
    /// "2 of 3 · Downloading from iCloud · 42%": the item among the run's and its stage.
    var subtitle: String
    /// The current stage's own progress, 0 to 1 (a download counts from 0, then the conversion from 0).
    var stageProgress: Double
    /// Whole-run progress, 0 to 1.
    var progress: Double
    /// Videos in the run still to finish, the running one included.
    var itemsRemaining: Int
    /// Videos in the run, finished or not.
    var totalItems: Int
    /// A video is being fetched (downloaded, or waiting its turn to be).
    var isDownloading: Bool
    /// What the stage says on its own: "Downloading from iCloud · 42%".
    var detail: String

    /// - Parameter runBaselineFinished: how many jobs had finished when the run began, so earlier history doesn't
    ///   count toward this run's total.
    init(jobs: [Job], runBaselineFinished: Int) {
        let summary = ActivitySummary(jobs: jobs)
        let totalFinished = summary.completed + summary.keptAsIs + summary.failed
        let runFinished = max(0, totalFinished - runBaselineFinished)
        let total = max(1, runFinished + summary.queue)
        let running = jobs.first {
            if case .running = $0.state { return true }
            return false
        }
        let current = running ?? jobs.first { $0.state == .queued }

        var fraction = 0.0
        if case .running(let value) = running?.state { fraction = value }
        let detail: String
        if running != nil {
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            detail = "\(Self.stageName(of: running)) · \(percent)%"
        } else {
            detail = current == nil ? "Converting" : "Waiting to start"
        }
        let index = min(total, runFinished + 1)

        self.isDownloading = running?.isDownloading ?? false
        self.stageProgress = fraction
        self.itemsRemaining = summary.queue
        self.totalItems = total
        self.progress = min(max((Double(runFinished) + (summary.runningProgress ?? 0)) / Double(total), 0), 1)
        self.detail = detail
        self.title = total == 1 ? "Converting 1 Video" : "Converting \(total) Videos"
        self.subtitle = total > 1 ? "\(index) of \(total) · \(detail)" : detail
    }

    /// The runner's own words without the trailing ellipsis: "Downloading from iCloud", "Converting".
    private static func stageName(of job: Job?) -> String {
        guard let phase = job?.phase?.trimmingCharacters(in: .whitespaces), !phase.isEmpty else { return "Converting" }
        return phase.trimmingCharacters(in: CharacterSet(charactersIn: "…."))
    }
}
