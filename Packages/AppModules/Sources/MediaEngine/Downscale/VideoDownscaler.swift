import AVFoundation
import AppCore
import CoreMedia
import Foundation

/// Re-encodes the primary video track at a smaller size (HEVC at the source bit depth, HDR, static HDR metadata and
/// Dolby Vision kept; or, for `.h264Compatible`, H.264 8-bit BT.709 SDR with HDR tone-mapped and its metadata
/// dropped; either way with the track's own metadata and language) and passes audio, timed metadata, file-level
/// metadata and file attributes through untouched, keeping each track's enabled state, alternate groups and audio
/// fallbacks.
public struct VideoDownscaler: Sendable {
    /// Test seam: runs with the partial file's URL once the writer has started (the partial exists, the final path
    /// is untouched), to inject a file appearing at the final path after the pre-check (another job writing the
    /// same name).
    var beforeStartWriting: (@Sendable (URL) -> Void)?
    /// Test seam: runs with the reader once video is finished, before the remaining passthrough samples are drained,
    /// to make the reader stop early (as a read failure would).
    var beforePassthroughDrain: (@Sendable (AVAssetReader) -> Void)?

    /// Test seam: where to force a stall (see `StallPoint`).
    var forceStall: StallPoint?
    /// Test seam: the slots to take, instead of the process-wide ones.
    var slots: WorkSlots?
    /// How long a run may go without progress before it fails as stalled.
    let stallLimits: StallLimits

    public init(stallLimits: StallLimits = .standard) {
        self.stallLimits = stallLimits
    }

    /// Writes a new file at `output`, in the container its extension names (`OutputContainer.fileType(for:)`:
    /// MPEG-4 for `.mp4` / `.m4v`, QuickTime otherwise). Throws `outputExists` if `output` exists, `sourceAlreadySmall` if the source
    /// short side is at most a non-nil `spec.targetShortSide`, and `unsupportedSource` for spatial video, all before
    /// writing. Output goes to a hidden partial file that is renamed to `output` only when complete (`outputExists`
    /// if `output` appeared meanwhile). On any failure or cancellation only the partial is deleted. Always runs
    /// off the caller's actor (`@concurrent`), so its blocking reads never land on a main-actor caller.
    @concurrent
    public func downscale(
        source: URL, output: URL, spec: DownscaleSpec, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // A few at a time (`WorkSlots`), each with its blocking reads on a queue of its own, never on the
        // shared pool (`BlockingWorkExecutor`).
        let slots = self.slots ?? WorkSlots.downscales
        await slots.acquire()
        let executor = BlockingWorkExecutor(label: "downscale \(output.lastPathComponent)")
        // The job runs as its own task, raced against a watchdog that reads its heartbeat. If the job is stuck in a
        // call that can't be interrupted (`copyNextSampleBuffer`, `completeFrames`), the watchdog fails this call
        // anyway, so the slot below is released; the stuck task is abandoned and ends when its call returns.
        let heartbeat = Heartbeat()
        do {
            try await StallWatchdog.race(heartbeat: heartbeat, limits: stallLimits) {
                try await withTaskExecutorPreference(executor) {
                    try await run(
                        source: source, output: output, spec: spec, heartbeat: heartbeat, progress: progress)
                }
            }
        } catch {
            await slots.release()
            throw error
        }
        await slots.release()
    }

    private func run(
        source: URL, output: URL, spec: DownscaleSpec, heartbeat: Heartbeat,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: output.path) { throw DownscaleError.outputExists }

        let asset = AVURLAsset(url: source)
        let inventory = try await MediaInspector().inventory(of: source)
        if inventory["hdr.stereo"] != nil { throw DownscaleError.unsupportedSource("spatial video") }
        guard let videoTrack = try await primaryVideoTrack(of: asset) else {
            throw DownscaleError.unsupportedSource("no video track")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        if let target = spec.targetShortSide, Int(min(naturalSize.width, naturalSize.height).rounded()) <= target {
            throw DownscaleError.sourceAlreadySmall
        }

        let partial = AtomicOutput.partialURL(for: output)

        let job = try await DownscaleJob(
            asset: asset, videoTrack: videoTrack, output: partial, fileType: OutputContainer.fileType(for: output),
            spec: spec,
            isTenBit: Self.encodesTenBit(bitDepth: inventory["video.bitDepth"]?.value),
            preservesDolbyVision: inventory["hdr.dolbyVision"] != nil, beforeStartWriting: beforeStartWriting,
            beforePassthroughDrain: beforePassthroughDrain, progress: progress, limits: stallLimits,
            forceStall: forceStall, heartbeat: heartbeat)
        heartbeat.register(partial: partial, abort: job.abortHandle())
        do {
            try await job.run()
            // The watchdog gave up on this run while it was stuck: it has already failed the caller, so commit nothing.
            if heartbeat.hasStalled { throw DownscaleError.stalled }
            try FileAttributes.copy(from: source, to: partial)
            try AtomicOutput.commit(partial: partial, to: output)
        } catch {
            // The partial's name is unique to this run, so removing it never touches anyone else's file.
            job.abort()
            try? FileManager.default.removeItem(at: partial)
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
