import AVFoundation
import AppCore
import Foundation

/// The container a downscale writes. It matches the source (spec 8.2): an MPEG-4 source stays MPEG-4 when that
/// container accepts every track the downscale copies; otherwise the output is QuickTime, which takes them all.
public enum OutputContainer {
    /// The writer's file type for an output path: MPEG-4 for `.mp4`, `.m4v` for `.m4v`, QuickTime otherwise.
    public static func fileType(for output: URL) -> AVFileType {
        switch output.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }

    /// Where a source's output goes: its extension, and whether that means leaving MPEG-4 for QuickTime.
    public struct Decision: Sendable, Equatable {
        /// The output's extension: the source's own (same spelling), or `mov`.
        public let pathExtension: String
        /// An `.mp4` or `.m4v` source is written as QuickTime because its container can't carry one of its
        /// tracks. That loses what `lostInQuickTimeFallback` lists.
        public let fallsBackToQuickTime: Bool

        public init(pathExtension: String, fallsBackToQuickTime: Bool) {
            self.pathExtension = pathExtension
            self.fallsBackToQuickTime = fallsBackToQuickTime
        }
    }

    /// The container for `source`'s output, from its extension and its tracks; nothing is written. A QuickTime or
    /// unknown source always gets `mov` (a `.mov` source keeps its own spelling, for example `MOV`); an MPEG-4
    /// source keeps its extension when its container can carry every audio and timed-metadata track.
    public static func decide(for source: URL) async throws -> Decision {
        let fileType = fileType(for: source)
        guard fileType != .mov else {
            return Decision(
                pathExtension: source.pathExtension.isEmpty ? "mov" : source.pathExtension,
                fallsBackToQuickTime: false)
        }
        return try await accepts(source: source, as: fileType)
            ? Decision(pathExtension: source.pathExtension, fallsBackToQuickTime: false)
            : Decision(pathExtension: "mov", fallsBackToQuickTime: true)
    }

    /// The extension the output takes (`decide(for:)`).
    public static func pathExtension(forSource source: URL) async throws -> String {
        try await decide(for: source).pathExtension
    }

    /// The file-level items an MPEG-4 source loses when its output is QuickTime: its ISO user data (`uiso/*`,
    /// such as the location `loci` and the date `date`). QuickTime has no such key space; the writer moves some of
    /// the values to QuickTime keys, but none keeps its key. Measured on MP4 and M4V fixtures: iTunes items
    /// (`itsk/*`) are kept, and nothing else is lost.
    public static func lostInQuickTimeFallback(_ inventory: MetadataInventory) -> [MetadataItem] {
        inventory.items.filter { $0.key.hasPrefix(isoUserDataPrefix) }
    }

    static let isoUserDataPrefix = "qt.\(AVMetadataKeySpace.isoUserData.rawValue)/"

    /// Whether a writer of `fileType` can add every audio and timed-metadata track of `source` unchanged. The
    /// video track is re-encoded to HEVC or H.264, which every MPEG-4 type carries.
    static func accepts(source: URL, as fileType: AVFileType) async throws -> Bool {
        let probe = FileManager.default.temporaryDirectory.appending(path: "container-probe-\(UUID().uuidString)")
        // A writer creates nothing on disk until it starts writing; this one never starts.
        let writer = try AVAssetWriter(outputURL: probe, fileType: fileType)
        let tracks = try await AVURLAsset(url: source).load(.tracks)
        for track in tracks where [.audio, .metadata].contains(track.mediaType) {
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            guard writer.canAdd(input) else { return false }
        }
        return true
    }
}
