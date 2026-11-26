import AppCore
import Foundation

/// The jobs made for a selection, and the files that couldn't get one.
public struct JobBatch: Sendable {
    public var jobs: [Job]
    /// Files that couldn't be bookmarked (for example, gone since they were added); they get no job.
    public var skipped: [URL]
}

/// Turns a selection into Convert jobs.
public enum JobFactory {
    /// One queued job per file, each carrying `settings` and a bookmark that follows the file if it moves. With
    /// `losses`, each job also records what it is predicted to lose (`losses[url]`, none when absent) for the queue's
    /// badge. A file that can't be bookmarked is skipped and listed in `skipped`; the others still get jobs.
    public static func makeJobs(
        for sources: [URL], settings: ConvertJobSettings, losses: [URL: PredictedLoss<UUID>]? = nil,
        now: Date = Date()
    ) -> JobBatch {
        makeJobs(
            for: sources.map { (url: $0, preset: settings.preset, bookmark: nil) }, settings: settings,
            losses: losses, now: now)
    }

    /// `makeJobs(for:settings:losses:now:)` with a preset per file (the inspector's per-video choice) in place of
    /// `settings.preset`.
    ///
    /// Each loss carries the names for showing and the keys the runner checks against.
    public static func makeJobs(
        for sources: [(url: URL, preset: Preset)], settings: ConvertJobSettings,
        losses: [URL: PredictedLoss<UUID>]? = nil, now: Date = Date()
    ) -> JobBatch {
        makeJobs(
            for: sources.map { (url: $0.url, preset: $0.preset, bookmark: nil) }, settings: settings,
            losses: losses, now: now)
    }

    public static func makeJobs(
        for sources: [(url: URL, preset: Preset, bookmark: Data?)], settings: ConvertJobSettings,
        losses: [URL: PredictedLoss<UUID>]? = nil, savings: [URL: Int64] = [:], now: Date = Date()
    ) -> JobBatch {
        var batch = JobBatch(jobs: [], skipped: [])
        for (url, preset, storedBookmark) in sources {
            let scoped = url.startAccessingSecurityScopedResource()
            let freshBookmark = try? url.bookmarkData(options: [])
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let bookmark = freshBookmark ?? storedBookmark else {
                batch.skipped.append(url)
                continue
            }
            var settings = settings
            settings.preset = preset
            settings.predictedLost = losses.map { $0[url]?.lost ?? [] }
            settings.predictedLostKeys = losses.map { $0[url]?.keys ?? [] }
            settings.estimatedSavedBytes = savings[url]
            guard let encoded = try? JSONEncoder().encode(settings) else {
                batch.skipped.append(url)
                continue
            }
            batch.jobs.append(
                Job(
                    toolID: ConvertTool.toolID, source: url, sourceBookmark: bookmark, settings: encoded,
                    createdAt: now))
        }
        return batch
    }
}
