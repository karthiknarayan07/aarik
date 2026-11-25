import AppCore
import Foundation

/// Turns a selection into Downscale Video jobs.
public enum JobFactory {
    /// One queued job per file, each carrying `settings` and a bookmark that follows the file if it moves.
    /// Throws when a file can't be bookmarked (for example, it no longer exists).
    public static func makeJobs(for sources: [URL], settings: DownscaleJobSettings, now: Date = Date()) throws
        -> [Job]
    {
        let encoded = try JSONEncoder().encode(settings)
        return try sources.map { url in
            Job(
                toolID: DownscaleTool.toolID, source: url, sourceBookmark: try url.bookmarkData(options: []),
                settings: encoded, createdAt: now)
        }
    }
}
