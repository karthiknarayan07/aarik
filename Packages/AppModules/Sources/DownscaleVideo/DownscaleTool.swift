import AppCore
import Foundation
import MediaEngine

/// Where the converted file goes.
public enum SaveDestination: Codable, Sendable, Equatable {
    case nextToOriginal
    case folder(bookmark: Data)
    case replace
}

/// The settings a Downscale Video job carries, encoded as JSON in `Job.settings`.
public struct DownscaleJobSettings: Codable, Sendable, Equatable {
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

    public init(
        preset: Preset, saveTo: SaveDestination, custom: DownscaleSpec? = nil, predictedLost: [String]? = nil,
        predictedLostKeys: [String]? = nil
    ) {
        self.preset = preset
        self.saveTo = saveTo
        self.custom = custom
        self.predictedLost = predictedLost
        self.predictedLostKeys = predictedLostKeys
    }
}

public struct DownscaleTool: Tool {
    public static let toolID = "downscale-video"

    public static let descriptor = ToolDescriptor(
        id: toolID, name: "Downscale Video", symbol: "arrow.down.right.and.arrow.up.left", category: .video)
}
