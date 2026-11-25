import AVFoundation
import AarikCore
import CoreMedia
import Foundation

/// Re-encodes the primary video track at a smaller size (HEVC at the source bit depth, HDR, static HDR metadata and
/// Dolby Vision kept, with the track's own metadata and language) and passes audio, timed metadata, file-level
/// metadata and file attributes through untouched, keeping each track's enabled state, alternate groups and audio
/// fallbacks.
public struct VideoDownscaler: Sendable {
    /// Test seam: runs with the output URL just before the writer starts, to inject a file appearing at the output
    /// path after the pre-check (another job writing the same name).
    var beforeStartWriting: (@Sendable (URL) -> Void)?
    /// Test seam: runs with the reader once video is finished, before the remaining passthrough samples are drained,
    /// to make the reader stop early (as a read failure would).
    var beforePassthroughDrain: (@Sendable (AVAssetReader) -> Void)?

    public init() {}

    /// Writes a new `.mov` at `output`. Throws `outputExists` if `output` exists, `sourceAlreadySmall` if the source
    /// short side is at most `spec.targetShortSide`, and `unsupportedSource` for spatial video, all before writing.
    /// On any later failure or cancellation the partial output is deleted and the error rethrown.
    public func downscale(
        source: URL, output: URL, spec: DownscaleSpec, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: output.path) { throw DownscaleError.outputExists }

        let asset = AVURLAsset(url: source)
        let inventory = try await MediaInspector().inventory(of: source)
        if inventory["hdr.stereo"] != nil { throw DownscaleError.unsupportedSource("spatial video") }
        guard let videoTrack = try await primaryVideoTrack(of: asset) else {
            throw DownscaleError.unsupportedSource("no video track")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        guard Int(min(naturalSize.width, naturalSize.height).rounded()) > spec.targetShortSide else {
            throw DownscaleError.sourceAlreadySmall
        }

        let job = try await DownscaleJob(
            asset: asset, videoTrack: videoTrack, output: output, spec: spec,
            isTenBit: Self.encodesTenBit(bitDepth: inventory["video.bitDepth"]?.value),
            preservesDolbyVision: inventory["hdr.dolbyVision"] != nil, beforeStartWriting: beforeStartWriting,
            beforePassthroughDrain: beforePassthroughDrain, progress: progress)
        do {
            try await job.run()
            try FileAttributes.copy(from: source, to: output)
        } catch {
            // Delete the output only if this run created it.
            if job.abort() { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        progress(1.0)
    }

    /// Main10 unless the source is known to be 8-bit: an unknown bit depth never drops to 8 bits.
    static func encodesTenBit(bitDepth: String?) -> Bool {
        bitDepth != "8"
    }

    private func primaryVideoTrack(of asset: AVAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        for track in tracks where try await track.load(.isEnabled) { return track }
        return tracks.first
    }
}
