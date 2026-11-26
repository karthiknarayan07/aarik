import Foundation
import os

/// The stages of a conversion that carry a signpost interval. The names are stable: they are what Instruments
/// (Points of Interest) and `PERFORMANCE.md` show, so renaming one breaks traces people compare.
public enum PipelineStage: String, CaseIterable, Sendable {
    /// Reading one video sample from the source (`AVAssetReader`).
    case read
    /// Scaling one frame (`VTPixelTransferSession`).
    case transfer
    /// Encoding one frame (`VTCompressionSession`).
    case encode
    /// Appending one encoded sample to the output, and finishing the file (`AVAssetWriter`).
    case write
    /// Reading the output back and comparing it with the source.
    case verify
    /// Getting a Photos video onto this Mac (iCloud download, or the copy of a local one, and an edit's render).
    case download
    /// Adding the converted video to Photos and checking it there.
    case save

    /// The interval's name. A `StaticString` per case, because signpost names must be literals.
    var name: StaticString {
        switch self {
        case .read: "read"
        case .transfer: "transfer"
        case .encode: "encode"
        case .write: "write"
        case .verify: "verify"
        case .download: "download"
        case .save: "save"
        }
    }
}

/// Signpost intervals around the pipeline's stages, all through one `OSSignposter` for the subsystem. They cost
/// next to nothing unless Instruments is recording.
public enum Signposts {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "AppCore"

    /// Category `pointsOfInterest`, so the intervals show in the Points of Interest instrument.
    public static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: subsystem, category: .pointsOfInterest))

    public static func interval<T>(_ stage: PipelineStage, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(stage.name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(stage.name, state) }
        return try body()
    }

    public static func interval<T>(
        _ stage: PipelineStage, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(stage.name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(stage.name, state) }
        return try await body()
    }
}
