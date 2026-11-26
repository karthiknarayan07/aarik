import AppCore
import Foundation
import PhotosLibrary

/// Turns a selection of Photos videos into jobs.
public enum PhotosJobFactory {
    /// One queued job per video, each with its own preset and what it is predicted to lose (`lost[assetID]`, none
    /// when absent; nil `lost` records no prediction at all). A job's source is the video's `x-photos-asset:`
    /// address with no bookmark; its file name travels in the settings, for the lists. `settings.saveTo` is not
    /// used for a Photos job; `destination` is.
    public static func makeJobs(
        for videos: [(assetID: String, name: String, preset: Preset)], settings: ConvertJobSettings,
        destination: PhotosDestination, lost: [String: [String]]? = nil, savings: [String: Int64] = [:],
        now: Date = Date()
    ) -> [Job] {
        videos.compactMap { video in
            var settings = settings
            settings.preset = video.preset
            settings.photosDestination = destination
            settings.photosFileName = video.name
            settings.predictedLost = lost.map { $0[video.assetID] ?? [] }
            settings.predictedLostKeys = nil
            settings.estimatedSavedBytes = savings[video.assetID]
            guard let encoded = try? JSONEncoder().encode(settings) else { return nil }
            return Job(
                toolID: ConvertTool.photosToolID, source: PhotoAssetURL.url(for: video.assetID),
                sourceBookmark: Data(), settings: encoded, createdAt: now)
        }
    }
}
