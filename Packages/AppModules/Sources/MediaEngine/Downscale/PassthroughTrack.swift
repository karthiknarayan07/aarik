import AVFoundation
import CoreMedia

/// An audio or timed-metadata track copied sample for sample.
final class PassthroughTrack {
    let trackID: CMPersistentTrackID
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let isTimedMetadata: Bool
    /// Source tracks this one falls back to (`AVAssetTrack.AssociationType.audioFallback`).
    let fallbackTrackIDs: [CMPersistentTrackID]
    private var next: CMSampleBuffer?
    private(set) var isFinished = false

    init(
        trackID: CMPersistentTrackID, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput,
        isTimedMetadata: Bool, fallbackTrackIDs: [CMPersistentTrackID]
    ) {
        self.trackID = trackID
        self.output = output
        self.input = input
        self.isTimedMetadata = isTimedMetadata
        self.fallbackTrackIDs = fallbackTrackIDs
    }

    /// Appends samples while the input is ready and the next sample starts at or before `limit`.
    /// Marks the input finished when the reader runs out. Returns whether anything was appended.
    /// `forceNotReady` is a test seam: the input never takes a sample.
    func pump(until limit: CMTime?, forceNotReady: Bool = false) throws -> Bool {
        var appended = false
        while !isFinished, !forceNotReady, input.isReadyForMoreMediaData {
            guard let sample = next ?? output.copyNextSampleBuffer() else {
                input.markAsFinished()
                isFinished = true
                break
            }
            if let limit, sample.presentationTimeStamp > limit {
                next = sample
                break
            }
            next = nil
            guard input.append(sample) else { throw DownscaleError.encoderFailed("passthrough append failed") }
            appended = true
        }
        return appended
    }
}
