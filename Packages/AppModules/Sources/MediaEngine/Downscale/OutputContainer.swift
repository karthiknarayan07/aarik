import AVFoundation
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

    /// The extension the output takes: the source's own (same spelling) when its container can carry every audio
    /// and timed-metadata track of the source, else `mov`. A QuickTime or unknown source always gets `mov`
    /// (a `.mov` source keeps its own spelling, for example `MOV`).
    public static func pathExtension(forSource source: URL) async throws -> String {
        let fileType = fileType(for: source)
        guard fileType != .mov else { return source.pathExtension.isEmpty ? "mov" : source.pathExtension }
        return try await accepts(source: source, as: fileType) ? source.pathExtension : "mov"
    }

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
