import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// One downscale run: reader → scaler → encoder → writer, with passthrough tracks interleaved by time.
/// Used from a single task only.
final class DownscaleJob {
    /// How far passthrough samples may run ahead of the latest video frame before the writer has to ask for them.
    private static let passthroughLead = CMTime(seconds: 1, preferredTimescale: 600)

    private let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let passthrough: [PassthroughTrack]
    private let videoTrackID: CMPersistentTrackID
    /// The video track's own metadata and language, copied onto the encoded track.
    private let videoMetadata: [AVMetadataItem]
    private let videoLanguage: (code: String?, extendedTag: String?)
    /// Alternate groups as source track IDs, with the member that was enabled.
    private let trackGroups: [(members: [CMPersistentTrackID], enabled: CMPersistentTrackID?)]
    private let transform: CGAffineTransform
    /// Ambient viewing environment from the source format description. VideoToolbox has no session property for
    /// it, so it rides on each frame as an attachment. Nil for H.264, which carries no HDR metadata.
    private let ambientViewingEnvironment: CFData?
    private let scaler: FrameScaler
    private let encoder: VideoEncoder
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let output: URL
    private let beforeStartWriting: (@Sendable (URL) -> Void)?
    private let beforePassthroughDrain: (@Sendable (AVAssetReader) -> Void)?
    /// Decode format: 10-bit for a 10-bit source, 8-bit for an 8-bit one. HEVC scales in it too; H.264 scales and
    /// tone-maps into 8-bit BT.709.
    private let pixelFormat: OSType

    private var limiter: FrameRateLimiter
    private var videoInput: AVAssetWriterInput?
    private var pending: (frame: CVPixelBuffer, time: CMTime)?
    private var lastSourceEnd = CMTime.zero
    private var reported = 0.0

    init(
        asset: AVURLAsset, videoTrack: AVAssetTrack, output: URL, spec: DownscaleSpec, isTenBit: Bool,
        preservesDolbyVision: Bool, beforeStartWriting: (@Sendable (URL) -> Void)?,
        beforePassthroughDrain: (@Sendable (AVAssetReader) -> Void)?, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        self.output = output
        self.beforeStartWriting = beforeStartWriting
        self.beforePassthroughDrain = beforePassthroughDrain
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
        func data(_ key: CFString) -> CFData? {
            description.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? Data } as CFData?
        }
        let expectedFrameRate = frameRate > 0 ? min(Double(frameRate), spec.maxFrameRate ?? .infinity) : nil
        switch spec.codec {
        case .hevcKeepHDR:
            ambientViewingEnvironment = data(kCMFormatDescriptionExtension_AmbientViewingEnvironment)
            encoder = try VideoEncoder(
                .init(
                    width: Int(size.width), height: Int(size.height), averageBitRate: spec.averageBitRate,
                    isTenBit: isTenBit, expectedFrameRate: expectedFrameRate,
                    colorPrimaries: color(kCMFormatDescriptionExtension_ColorPrimaries),
                    transferFunction: color(kCMFormatDescriptionExtension_TransferFunction),
                    matrix: color(kCMFormatDescriptionExtension_YCbCrMatrix),
                    masteringDisplay: data(kCMFormatDescriptionExtension_MasteringDisplayColorVolume),
                    contentLightLevel: data(kCMFormatDescriptionExtension_ContentLightLevelInfo),
                    preservesDolbyVision: preservesDolbyVision))
            scaler = try FrameScaler(width: Int(size.width), height: Int(size.height), pixelFormat: pixelFormat)
        case .h264Compatible:
            ambientViewingEnvironment = nil
            encoder = try VideoEncoder(
                .h264(
                    width: Int(size.width), height: Int(size.height), averageBitRate: spec.averageBitRate,
                    expectedFrameRate: expectedFrameRate))
            scaler = try FrameScaler(
                width: Int(size.width), height: Int(size.height),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, toSDR709: true)
        }
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
        videoTrackID = videoTrack.trackID
        videoMetadata = try await videoTrack.load(.metadata)
        videoLanguage = (try await videoTrack.load(.languageCode), try await videoTrack.load(.extendedLanguageTag))
        trackGroups = try await Self.groups(of: asset)

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
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            input.metadata = try await track.load(.metadata)
            if let language = try await track.load(.languageCode) { input.languageCode = language }
            if let tag = try await track.load(.extendedLanguageTag) { input.extendedLanguageTag = tag }
            let fallbacks = try await track.loadAssociatedTracks(ofType: .audioFallback).map(\.trackID)
            passthrough.append(
                PassthroughTrack(
                    trackID: track.trackID, output: readerOutput, input: input,
                    isTimedMetadata: track.mediaType == .metadata, fallbackTrackIDs: fallbacks))
        }
        self.passthrough = passthrough
    }

    private static func groups(of asset: AVAsset) async throws
        -> [(members: [CMPersistentTrackID], enabled: CMPersistentTrackID?)]
    {
        var result: [(members: [CMPersistentTrackID], enabled: CMPersistentTrackID?)] = []
        for group in try await asset.load(.trackGroups) {
            let members = group.trackIDs.map(\.int32Value)
            var enabled: CMPersistentTrackID?
            for id in members {
                if let track = try await asset.loadTrack(withTrackID: id), try await track.load(.isEnabled) {
                    enabled = id
                    break
                }
            }
            result.append((members, enabled))
        }
        return result
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
            let scaled = try scaler.scale(frame)
            if let ambientViewingEnvironment,
                CVBufferCopyAttachment(scaled, kCVImageBufferAmbientViewingEnvironmentKey, nil) == nil
            {
                CVBufferSetAttachment(
                    scaled, kCVImageBufferAmbientViewingEnvironmentKey, ambientViewingEnvironment, .shouldPropagate)
            }
            pending = (scaled, time)
            try pumpPassthrough(until: time + Self.passthroughLead)
        }
        // nil from `copyNextSampleBuffer()` means the end of the track or that the reader stopped; only the status
        // tells them apart.
        guard reader.status == .reading || reader.status == .completed else { throw readerError() }
        try Task.checkCancellation()

        try await submitPending(nextTime: lastSourceEnd)
        try encoder.completeFrames()
        try await appendEncoded()
        guard let videoInput else { throw DownscaleError.unsupportedSource("no video frames") }
        videoInput.markAsFinished()
        beforePassthroughDrain?(reader)
        // Feed every unfinished track on each pass: the writer interleaves its inputs, so one track can stay not
        // ready until another catches up. Draining one track at a time can hang.
        while passthrough.contains(where: { !$0.isFinished }) {
            try Task.checkCancellation()
            try checkWriter()
            if try !pumpPassthrough(until: nil) { try await Task.sleep(for: .milliseconds(1)) }
        }
        try Task.checkCancellation()
        // Every output has returned nil; anything but `.completed` means some track was cut short.
        guard reader.status == .completed else { throw readerError() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writerError() }
    }

    /// Stops reading and writing after a failure or cancellation. The caller deletes the partial file.
    func abort() {
        reader.cancelReading()
        if writer.status == .writing { writer.cancelWriting() }
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
            // The writer needs the encoder's own format description (with its hvcC/avcC and dvvC atoms) as the hint.
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
        input.metadata = videoMetadata
        if let code = videoLanguage.code { input.languageCode = code }
        if let tag = videoLanguage.extendedTag { input.extendedLanguageTag = tag }
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
        addFallbacksAndGroups(videoInput: input)
        guard writer.startWriting() else { throw writerError() }
        beforeStartWriting?(output)
        writer.startSession(atSourceTime: .zero)
        videoInput = input
        return input
    }

    /// Recreates audio fallback associations and alternate groups among the copied tracks. Anything the writer
    /// refuses is left out (and then shows as changed or lost in the report) rather than raising an exception.
    private func addFallbacksAndGroups(videoInput: AVAssetWriterInput) {
        var inputs = [videoTrackID: videoInput]
        for track in passthrough { inputs[track.trackID] = track.input }
        let fallback = AVAssetTrack.AssociationType.audioFallback.rawValue
        for track in passthrough {
            for id in track.fallbackTrackIDs {
                guard let other = inputs[id], track.input.canAddTrackAssociation(withTrackOf: other, type: fallback)
                else { continue }
                track.input.addTrackAssociation(withTrackOf: other, type: fallback)
            }
        }
        for group in trackGroups {
            let members = group.members.compactMap { inputs[$0] }
            guard !members.isEmpty else { continue }
            let writerGroup = AVAssetWriterInputGroup(
                inputs: members, defaultInput: group.enabled.flatMap { inputs[$0] })
            if writer.canAdd(writerGroup) { writer.add(writerGroup) }
        }
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
