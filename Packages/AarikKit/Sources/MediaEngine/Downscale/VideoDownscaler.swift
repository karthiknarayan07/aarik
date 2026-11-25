import AVFoundation
import AarikCore
import CoreMedia
import Foundation

/// Re-encodes the primary video track at a smaller size (HEVC at the source bit depth, HDR and Dolby Vision kept) and
/// passes audio, timed metadata, file-level metadata and file attributes through untouched.
public struct VideoDownscaler: Sendable {
    /// Test seam: runs with the output URL just before the writer starts, to inject a file appearing at the output
    /// path after the pre-check (another job writing the same name).
    var beforeStartWriting: (@Sendable (URL) -> Void)?

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
            isTenBit: inventory["video.bitDepth"]?.value != "8",
            preservesDolbyVision: inventory["hdr.dolbyVision"] != nil, beforeStartWriting: beforeStartWriting,
            progress: progress)
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

    private func primaryVideoTrack(of asset: AVAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        for track in tracks where try await track.load(.isEnabled) { return track }
        return tracks.first
    }
}

/// One downscale run: reader → scaler → encoder → writer, with passthrough tracks interleaved by time.
/// Used from a single task only.
private final class DownscaleJob {
    /// How far passthrough samples may run ahead of the latest video frame before the writer has to ask for them.
    private static let passthroughLead = CMTime(seconds: 1, preferredTimescale: 600)

    private let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let passthrough: [PassthroughTrack]
    private let transform: CGAffineTransform
    private let scaler: FrameScaler
    private let encoder: HEVCEncoder
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let output: URL
    private let beforeStartWriting: (@Sendable (URL) -> Void)?
    /// Decode and scale format: 10-bit for a 10-bit source, 8-bit for an 8-bit one.
    private let pixelFormat: OSType

    private var limiter: FrameRateLimiter
    private var videoInput: AVAssetWriterInput?
    private var pending: (frame: CVPixelBuffer, time: CMTime)?
    private var lastSourceEnd = CMTime.zero
    private var reported = 0.0
    /// Set only once `startWriting()` succeeds: from then on the output file is this run's.
    private var didStartWriting = false

    init(
        asset: AVURLAsset, videoTrack: AVAssetTrack, output: URL, spec: DownscaleSpec, isTenBit: Bool,
        preservesDolbyVision: Bool, beforeStartWriting: (@Sendable (URL) -> Void)?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        self.output = output
        self.beforeStartWriting = beforeStartWriting
        let pixelFormat =
            isTenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        self.pixelFormat = pixelFormat
        let (naturalSize, transform, descriptions, frameRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .formatDescriptions, .nominalFrameRate)
        let size = spec.outputSize(forNaturalSize: naturalSize)
        let description = descriptions.first
        func color(_ key: CFString) -> CFString? {
            description.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? String } as CFString?
        }
        encoder = try HEVCEncoder(
            .init(
                width: Int(size.width), height: Int(size.height), averageBitRate: spec.averageBitRate,
                isTenBit: isTenBit,
                expectedFrameRate: frameRate > 0 ? min(Double(frameRate), spec.maxFrameRate ?? .infinity) : nil,
                colorPrimaries: color(kCMFormatDescriptionExtension_ColorPrimaries),
                transferFunction: color(kCMFormatDescriptionExtension_TransferFunction),
                matrix: color(kCMFormatDescriptionExtension_YCbCrMatrix),
                preservesDolbyVision: preservesDolbyVision))
        scaler = try FrameScaler(width: Int(size.width), height: Int(size.height), pixelFormat: pixelFormat)
        self.transform = transform
        self.progress = progress
        limiter = FrameRateLimiter(maxFrameRate: spec.maxFrameRate)
        duration = try await asset.load(.duration).seconds

        reader = try AVAssetReader(asset: asset)
        videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw DownscaleError.unsupportedSource("the video track cannot be decoded")
        }
        reader.add(videoOutput)

        writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.metadata = try await asset.load(.metadata)

        var passthrough: [PassthroughTrack] = []
        for track in try await asset.load(.tracks) where [.audio, .metadata].contains(track.mediaType) {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            // A track either end refuses (an odd format) is skipped, so it shows up as lost in the report; adding it
            // anyway would raise an Objective-C exception. Both checks run before the reader output is added, so a
            // skipped track leaves no reader output undrained.
            guard reader.canAdd(readerOutput), writer.canAdd(input) else { continue }
            reader.add(readerOutput)
            input.expectsMediaDataInRealTime = false
            input.metadata = try await track.load(.metadata)
            if let language = try await track.load(.languageCode) { input.languageCode = language }
            if let tag = try await track.load(.extendedLanguageTag) { input.extendedLanguageTag = tag }
            passthrough.append(
                PassthroughTrack(output: readerOutput, input: input, isTimedMetadata: track.mediaType == .metadata))
        }
        self.passthrough = passthrough
    }

    func run() async throws {
        guard reader.startReading() else { throw readerError() }
        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = sample.presentationTimeStamp
            let sampleDuration = sample.duration
            lastSourceEnd = sampleDuration.isValid ? time + sampleDuration : time
            guard limiter.shouldKeep(presentationTime: time), let frame = sample.imageBuffer else { continue }
            try await submitPending(nextTime: time)
            pending = (try scaler.scale(frame), time)
            try pumpPassthrough(until: time + Self.passthroughLead)
        }
        if reader.status == .failed { throw readerError() }
        try Task.checkCancellation()

        try await submitPending(nextTime: lastSourceEnd)
        try encoder.completeFrames()
        try await appendEncoded()
        guard let videoInput else { throw DownscaleError.unsupportedSource("no video frames") }
        videoInput.markAsFinished()
        // Feed every unfinished track on each pass: the writer interleaves its inputs, so one track can stay not
        // ready until another catches up. Draining one track at a time can hang.
        while passthrough.contains(where: { !$0.isFinished }) {
            try Task.checkCancellation()
            try checkWriter()
            if try !pumpPassthrough(until: nil) { try await Task.sleep(for: .milliseconds(1)) }
        }
        try Task.checkCancellation()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writerError() }
    }

    /// Stops reading and writing after a failure or cancellation. Returns whether this run created the output file
    /// (`startWriting()` succeeded), which the caller then deletes.
    func abort() -> Bool {
        reader.cancelReading()
        if writer.status == .writing { writer.cancelWriting() }
        return didStartWriting
    }

    // MARK: - Video

    /// Encodes the held-back frame, lasting until the next kept frame (or the source end), so dropped frames
    /// lengthen the kept ones and the video keeps its duration.
    private func submitPending(nextTime: CMTime) async throws {
        guard let pending else { return }
        self.pending = nil
        let frameDuration = nextTime > pending.time ? nextTime - pending.time : CMTime.invalid
        try encoder.encode(pending.frame, presentationTime: pending.time, duration: frameDuration)
        if videoInput == nil {
            // The writer needs the encoder's own format description (with its hvcC and dvvC atoms) as the hint.
            try encoder.completeFrames()
        }
        try await appendEncoded()
    }

    private func appendEncoded() async throws {
        for sample in try encoder.takeEncoded() {
            let input = try videoInput ?? startWriting(hint: sample.formatDescription)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try checkWriter()
                if try !pumpPassthrough(until: nil) { try await Task.sleep(for: .milliseconds(1)) }
            }
            guard input.append(sample) else { throw writerError() }
            let fraction = duration > 0 ? min(sample.presentationTimeStamp.seconds / duration, 1) : 0
            if fraction > reported {
                reported = fraction
                progress(fraction)
            }
        }
    }

    // MARK: - Writer

    private func startWriting(hint: CMFormatDescription?) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        guard writer.canAdd(input) else {
            throw DownscaleError.unsupportedSource("the writer refused the encoded video format")
        }
        writer.add(input)
        let referent = AVAssetTrack.AssociationType.metadataReferent.rawValue
        for track in passthrough {
            // `writer.canAdd(track.input)` was checked when the track was set up.
            if track.isTimedMetadata, track.input.canAddTrackAssociation(withTrackOf: input, type: referent) {
                track.input.addTrackAssociation(withTrackOf: input, type: referent)
            }
            writer.add(track.input)
        }
        beforeStartWriting?(output)
        // `startWriting()` fails (status `.failed`) when a file already exists at the output path, for example one
        // another job wrote after the pre-check. Only a successful start makes the output this run's.
        guard writer.startWriting() else { throw writerError() }
        didStartWriting = true
        writer.startSession(atSourceTime: .zero)
        videoInput = input
        return input
    }

    /// Appends ready passthrough samples up to `limit` (nil: no limit). Returns whether anything was appended.
    @discardableResult
    private func pumpPassthrough(until limit: CMTime?) throws -> Bool {
        guard videoInput != nil else { return false }
        var appended = false
        for track in passthrough where try track.pump(until: limit) { appended = true }
        return appended
    }

    private func checkWriter() throws {
        if writer.status == .failed || writer.status == .cancelled { throw writerError() }
    }

    private func writerError() -> DownscaleError {
        .encoderFailed("writer: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
    }

    private func readerError() -> DownscaleError {
        .encoderFailed("reader: \(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")")
    }
}

/// An audio or timed-metadata track copied sample for sample.
private final class PassthroughTrack {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let isTimedMetadata: Bool
    private var next: CMSampleBuffer?
    private(set) var isFinished = false

    init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, isTimedMetadata: Bool) {
        self.output = output
        self.input = input
        self.isTimedMetadata = isTimedMetadata
    }

    /// Appends samples while the input is ready and the next sample starts at or before `limit`.
    /// Marks the input finished when the reader runs out. Returns whether anything was appended.
    func pump(until limit: CMTime?) throws -> Bool {
        var appended = false
        while !isFinished, input.isReadyForMoreMediaData {
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
