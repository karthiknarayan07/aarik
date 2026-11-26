import AppCore
import Foundation
import MediaEngine

/// Where the converted file goes.
public enum SaveDestination: Codable, Sendable, Equatable {
    case nextToOriginal
    case folder(bookmark: Data)
    case replace
}

/// Where a Photos video's converted copy goes.
public enum PhotosDestination: Codable, Sendable, Equatable {
    /// Photos, as a new video next to the original (the default; the original is never touched).
    case newAsset
    /// Photos, as a new video; the original is then moved to Recently Deleted (after a batch confirmation).
    case replace
    /// A folder on this Mac, with the normal naming; nothing in Photos changes.
    case folder(bookmark: Data)
}

/// The settings a Downscale Video job carries, encoded as JSON in `Job.settings`.
public struct ConvertJobSettings: Codable, Sendable, Equatable {
    public var preset: Preset
    public var saveTo: SaveDestination
    /// When set, wins over `preset`.
    public var custom: DownscaleSpec?
    /// What the planner predicted, when the job was added, that converting loses (display names, as shown);
    /// empty for nothing. Nil for jobs saved before this was recorded.
    public var predictedLost: [String]?
    /// The keys of the items in `predictedLost`: what the runner checks a loss against. Nil for jobs saved before
    /// keys were recorded (the runner then compares names).
    public var predictedLostKeys: [String]?
    /// For a Photos job: where its copy goes (`saveTo` is not used). Nil for a job on a file.
    public var photosDestination: PhotosDestination?
    /// For a Photos job: the video's file name in Photos, for showing in the lists (the job's source is an
    /// address, not a file).
    public var photosFileName: String?

    public init(
        preset: Preset, saveTo: SaveDestination, custom: DownscaleSpec? = nil, predictedLost: [String]? = nil,
        predictedLostKeys: [String]? = nil, photosDestination: PhotosDestination? = nil,
        photosFileName: String? = nil
    ) {
        self.preset = preset
        self.saveTo = saveTo
        self.custom = custom
        self.predictedLost = predictedLost
        self.predictedLostKeys = predictedLostKeys
        self.photosDestination = photosDestination
        self.photosFileName = photosFileName
    }
}

public struct ConvertTool: Tool {
    public static let toolID = "downscale-video"
    /// The same conversion on a video in the Photos library; its jobs have an `x-photos-asset:` source.
    public static let photosToolID = "downscale-video-photos"

    public static let descriptor = ToolDescriptor(
        id: toolID, name: "Downscale Video", symbol: "arrow.down.right.and.arrow.up.left", category: .video)
}
