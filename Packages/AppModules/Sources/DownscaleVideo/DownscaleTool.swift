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

    public init(preset: Preset, saveTo: SaveDestination, custom: DownscaleSpec? = nil) {
        self.preset = preset
        self.saveTo = saveTo
        self.custom = custom
    }
}

public struct DownscaleTool: Tool {
    public static let toolID = "downscale-video"

    public static let descriptor = ToolDescriptor(
        id: toolID, name: "Downscale Video", symbol: "arrow.down.right.and.arrow.up.left", category: .video)
}
