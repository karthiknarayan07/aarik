import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MediaEngine
import VideoToolbox

public enum FixtureHDR: Sendable { case sdr, hlg }

public struct ClipOptions: Sendable {
    public var width = 3840
    public var height = 2160
    public var fps = 30
    public var seconds = 1.0
    /// Frames at uneven intervals (alternately 1.5 and 0.5 frame periods apart, the average still `fps`), as a
    /// screen recording or a dropped-frame capture has; false spaces them evenly.
    /// Such a clip has no audio: with it the writer was seen to stop taking video (cause not found), so
    /// `includeAudio` is ignored.
    public var variableFrameRate = false
    public var hdr: FixtureHDR = .hlg
    /// key → string value, keySpace mdta
    public var quickTimeMetadata: [String: String] = [:]
    /// More file-level items in any key space (written after `quickTimeMetadata`), as the container keeps them.
    public var fileMetadata: [FixtureMetadataItem] = []
    /// stereo AAC 48 kHz
    public var includeAudio = true
    /// With audio: a second stereo AAC track, disabled, in one alternate group with the first, which falls back to it
    /// (the shape of an iPhone spatial-audio clip's fallback track).
    public var includeFallbackAudioTrack = false
    /// How much longer than the video the audio runs (with audio only); the timed metadata spans the audio length.
    public var audioTailSeconds = 0.0
    /// Adds the timed-metadata track before the audio track (default: audio first).
    public var timedMetadataBeforeAudio = false
    /// one mebx track, identifier `mdta/com.example.fixture.timed`, one group per second of the clip (and audio tail)
    public var includeTimedMetadataTrack = false
    /// 0 or 90 → preferredTransform
    public var rotationDegrees = 0
    /// key → string value, keySpace mdta, on the video track itself
    public var videoTrackMetadata: [String: String] = [:]
    /// ISO 639-2/T code for the video track
    public var videoLanguage: String?
    /// Static HDR metadata (raw SEI payload bytes, as in the CoreMedia extensions); nil leaves it out. Mastering
    /// display and content light level are encoder properties; ambient viewing environment has no encoder property,
    /// so it is attached to every frame.
    public var masteringDisplay: Data?
    public var contentLightLevel: Data?
    public var ambientViewingEnvironment: Data?
    /// Still frames of equal-width vertical stripes at these signal levels (0 = video-range black, 1 = video-range
    /// white) with neutral chroma, in place of the moving gradient; nil keeps the gradient.
    public var lumaStripes: [Double]?
    /// Average encode bit rate in bits per second; nil uses 2 bits per pixel per second.
    public var videoBitRate: Int?
    public var finderTags: [String] = []
    public var extendedAttributes: [String: Data] = [:]
    /// The container: `.mov` (default), `.mp4` or `.m4v`; the file gets the matching extension.
    public var fileType: AVFileType = .mov

    public init() {}
}

/// A file-level metadata item in a given key space, with a UTF-8 string value.
public struct FixtureMetadataItem: Sendable {
    public var keySpace: AVMetadataKeySpace
    public var key: String
    public var value: String

    public init(keySpace: AVMetadataKeySpace, key: String, value: String) {
        self.keySpace = keySpace
        self.key = key
        self.value = value
    }
}

public enum FixtureError: Error, Sendable {
    case writerFailed(String)
    case pixelBufferFailed(Int32)
    case audioBufferFailed(Int32)
    case metadataFormatFailed(Int32)
    case xattrFailed(String, Int32)
}

public enum FixtureFactory {
    public static let timedMetadataIdentifier = "mdta/com.example.fixture.timed"
    private static let sampleRate = 48_000

    /// Writes a new clip (`fixture.mov`, or `.mp4` / `.m4v` per `options.fileType`) into a fresh temporary
    /// directory and returns its URL.
    public static func makeClip(_ options: ClipOptions = .init()) async throws -> URL {
        // Tests make many clips at once, beside the downscales they run. One clip at a time: with several, the
        // hardware encoder was seen to miss the requested bit rate by orders of magnitude, and the writer to stop
        // taking video for good (a clip takes a fraction of a second, so the queue stays short).
        await slots.acquire()
        do {
            let clip = try await writeClip(options)
            await slots.release()
            return clip
        } catch {
            await slots.release()
            throw error
        }
    }

    /// One fixture at a time (concurrent writers were seen to stall). A test's time limit includes its wait in this
    /// queue, so tests that build fixtures carry 5 minutes, not 2: the limit is only there to catch a hang, and a
    /// stalled fixture already fails by itself after 30 seconds. (Caching fixtures was the alternative; nearly every
    /// test needs its own options, and many damage or rewrite the clip, so a cache would rarely hit.)
    private static let slots = WorkSlots(count: 1)

    private static func writeClip(_ options: ClipOptions) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext =
            switch options.fileType {
            case .mp4: "mp4"
            case .m4v: "m4v"
            default: "mov"
            }
        let url = dir.appending(path: "fixture.\(ext)")

        let writer = try AVAssetWriter(outputURL: url, fileType: options.fileType)
        let hlg = options.hdr == .hlg

        var compression: [String: Any] = [
            AVVideoProfileLevelKey: hlg
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoAverageBitRateKey: options.videoBitRate ?? max(options.width * options.height * 2, 1_000_000),
        ]
        let staticHDR: [(CFString, Data?)] = [
            (kVTCompressionPropertyKey_MasteringDisplayColorVolume, options.masteringDisplay),
            (kVTCompressionPropertyKey_ContentLightLevelInfo, options.contentLightLevel),
        ]
        for case let (key, data?) in staticHDR { compression[key as String] = data }

        // Video
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: options.width,
                AVVideoHeightKey: options.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: hlg
                        ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: hlg
                        ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: hlg ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: compression,
            ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.metadata = quickTimeItems(options.videoTrackMetadata)
        if let language = options.videoLanguage { videoInput.languageCode = language }
        if options.rotationDegrees == 90 {
            videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }
        let pixelFormat =
            hlg ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: options.width,
                kCVPixelBufferHeightKey as String: options.height,
            ])
        writer.add(videoInput)

        // Audio
        var audioInputs: [AVAssetWriterInput] = []
        if options.includeAudio && !options.variableFrameRate {
            for _ in 0..<(options.includeFallbackAudioTrack ? 2 : 1) {
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 128_000,
                    ])
                input.expectsMediaDataInRealTime = false
                audioInputs.append(input)
            }
        }

        // Timed metadata
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if options.includeTimedMetadataTrack {
            var format: CMFormatDescription?
            let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [
                    [
                        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                            timedMetadataIdentifier,
                        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                            kCMMetadataBaseDataType_UTF8 as String,
                    ]
                ] as CFArray,
                formatDescriptionOut: &format)
            guard status == noErr, let format else { throw FixtureError.metadataFormatFailed(status) }
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.addTrackAssociation(
                withTrackOf: videoInput, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
            metadataInput = input
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        }

        let passthroughInputs = audioInputs + [metadataInput].compactMap(\.self)
        for input in options.timedMetadataBeforeAudio ? passthroughInputs.reversed() : passthroughInputs {
            writer.add(input)
        }
        if audioInputs.count == 2 {
            let (main, fallback) = (audioInputs[0], audioInputs[1])
            fallback.marksOutputTrackAsEnabled = false
            main.addTrackAssociation(
                withTrackOf: fallback, type: AVAssetTrack.AssociationType.audioFallback.rawValue)
            writer.add(AVAssetWriterInputGroup(inputs: [main, fallback], defaultInput: main))
        }

        // File-level QuickTime metadata
        writer.metadata = quickTimeItems(options.quickTimeMetadata) + options.fileMetadata.map(metadataItem)

        do {
            guard writer.startWriting() else {
                throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: .zero)

            // Frames, with audio (which may run on past the last frame) and timed metadata interleaved. Timed
            // metadata is one group per second over the audio length (one group for a clip of a second or less).
            let frameCount = max(1, Int((options.seconds * Double(options.fps)).rounded()))
            let audioFrameCount =
                audioInputs.isEmpty
                ? 0 : Int(((options.seconds + options.audioTailSeconds) * Double(options.fps)).rounded())
            let timedSeconds = options.seconds + (audioInputs.isEmpty ? 0 : options.audioTailSeconds)
            let groupCount = max(1, Int(timedSeconds.rounded(.up)))
            var groupsWritten = 0
            // The writer interleaves its inputs by time and holds back an input that runs far ahead of the others.
            // Waiting on one input while another starves therefore deadlocks, so every wait feeds the audio too.
            let feeder = AudioFeeder(
                inputs: audioInputs, writer: writer, totalSamples: audioFrameCount * sampleRate / options.fps)
            let feedAudio: () throws -> Void = { try feeder.pump(limit: .max) }
            for frame in 0..<max(frameCount, audioFrameCount) {
                if let metadataAdaptor, let metadataInput, groupsWritten < groupCount,
                    Double(frame) / Double(options.fps) >= Double(groupsWritten)
                {
                    try await appendTimedGroup(
                        groupsWritten, totalSeconds: timedSeconds, adaptor: metadataAdaptor, input: metadataInput,
                        writer: writer, whileWaiting: feedAudio)
                    groupsWritten += 1
                    if groupsWritten == groupCount { metadataInput.markAsFinished() }
                }
                if frame < frameCount {
                    try await waitUntilReady(videoInput, writer: writer, whileWaiting: feedAudio)
                    guard let pool = adaptor.pixelBufferPool else {
                        throw FixtureError.writerFailed("no pixel buffer pool")
                    }
                    var pixelBuffer: CVPixelBuffer?
                    let cv = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                    guard cv == kCVReturnSuccess, let pixelBuffer else { throw FixtureError.pixelBufferFailed(cv) }
                    if let stripes = options.lumaStripes {
                        fillStripes(pixelBuffer, levels: stripes, hlg: hlg)
                    } else {
                        fill(pixelBuffer, frame: frame, hlg: hlg)
                    }
                    if let ambient = options.ambientViewingEnvironment {
                        CVBufferSetAttachment(
                            pixelBuffer, kCVImageBufferAmbientViewingEnvironmentKey, ambient as CFData,
                            .shouldPropagate)
                    }
                    let pts =
                        options.variableFrameRate
                        ? CMTime(value: CMTimeValue(2 * frame + frame % 2), timescale: CMTimeScale(2 * options.fps))
                        : CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(options.fps))
                    guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                        throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "video append failed")
                    }
                    if frame == frameCount - 1 { videoInput.markAsFinished() }
                }
                try feedAudio()
            }
            if let metadataAdaptor, let metadataInput, groupsWritten < groupCount {
                for index in groupsWritten..<groupCount {
                    try await appendTimedGroup(
                        index, totalSeconds: timedSeconds, adaptor: metadataAdaptor, input: metadataInput,
                        writer: writer, whileWaiting: feedAudio)
                }
                metadataInput.markAsFinished()
            }
            while !feeder.isDone {
                try feedAudio()
                if feeder.isDone { break }
                if writer.status == .failed || writer.status == .cancelled {
                    throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "writer \(writer.status)")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            for audioInput in audioInputs { audioInput.markAsFinished() }

            await writer.finishWriting()
            guard writer.status == .completed else {
                throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "finishWriting failed")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        // Finder tags and extended attributes
        #if os(macOS)
            if !options.finderTags.isEmpty {
                var values = URLResourceValues()
                values.tagNames = options.finderTags
                var mutableURL = url
                try mutableURL.setResourceValues(values)
            }
        #endif
        for (name, data) in options.extendedAttributes {
            let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
            if result != 0 { throw FixtureError.xattrFailed(name, errno) }
        }
        return url
    }

    // MARK: - Helpers

    private static func quickTimeItems(_ values: [String: String]) -> [AVMetadataItem] {
        values.sorted { $0.key < $1.key }.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
    }

    private static func metadataItem(_ fixture: FixtureMetadataItem) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = fixture.keySpace
        item.key = fixture.key as NSString
        item.value = fixture.value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// Appends timed-metadata group `index`, covering second `index` (clipped to `totalSeconds`).
    private static func appendTimedGroup(
        _ index: Int, totalSeconds: Double, adaptor: AVAssetWriterInputMetadataAdaptor, input: AVAssetWriterInput,
        writer: AVAssetWriter, whileWaiting: () throws -> Void
    ) async throws {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: timedMetadataIdentifier)
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = "fixture-timed-\(index)" as NSString
        let start = Double(index)
        let end = min(start + 1, totalSeconds)
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))
        try await waitUntilReady(input, writer: writer, whileWaiting: whileWaiting)
        guard adaptor.append(AVTimedMetadataGroup(items: [item], timeRange: range)) else {
            throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "metadata append failed")
        }
    }

    /// Feeds the audio inputs without ever blocking: `pump` appends what each input accepts right now.
    private final class AudioFeeder {
        private let inputs: [AVAssetWriterInput]
        private let writer: AVAssetWriter
        private let totalSamples: Int
        private var written: [Int]
        private static let chunk = 1600

        init(inputs: [AVAssetWriterInput], writer: AVAssetWriter, totalSamples: Int) {
            self.inputs = inputs
            self.writer = writer
            self.totalSamples = totalSamples
            written = [Int](repeating: 0, count: inputs.count)
        }

        var isDone: Bool { written.allSatisfy { $0 >= totalSamples } }

        /// Appends audio, up to `limit` samples in all, while an input is ready for more.
        func pump(limit: Int) throws {
            let end = min(limit, totalSamples)
            for (index, input) in inputs.enumerated() {
                while written[index] < end, input.isReadyForMoreMediaData {
                    let count = min(Self.chunk, end - written[index])
                    let buffer = try FixtureFactory.makeAudioBuffer(startSample: written[index], count: count)
                    guard input.append(buffer) else {
                        throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "audio append failed")
                    }
                    written[index] += count
                }
            }
        }
    }

    /// Waits until `input` takes more data. While it doesn't, `whileWaiting` feeds the other inputs: the writer holds
    /// this one back until they catch up.
    private static func waitUntilReady(
        _ input: AVAssetWriterInput, writer: AVAssetWriter, whileWaiting: () throws -> Void = {}
    ) async throws {
        // A writer that never takes more data would hang the test run (a time limit can't interrupt a wait that
        // keeps running), so a stall fails the clip instead. The simulator's software encoder is much slower
        // under parallel test load, so give it more headroom before declaring a stall.
        #if targetEnvironment(simulator)
            let timeout = Duration.seconds(90)
        #else
            let timeout = Duration.seconds(30)
        #endif
        let deadline = ContinuousClock.now + timeout
        while !input.isReadyForMoreMediaData {
            if ContinuousClock.now > deadline {
                throw FixtureError.writerFailed("stalled: \(input.mediaType.rawValue) input not ready for \(timeout)")
            }
            if writer.status == .failed || writer.status == .cancelled {
                throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "writer \(writer.status)")
            }
            try whileWaiting()
            if input.isReadyForMoreMediaData { break }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Fills vertical stripes of flat grey, one per level, with neutral chroma.
    private static func fillStripes(_ buffer: CVPixelBuffer, levels: [Double], hlg: Bool) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        func level(atColumn x: Int) -> Double { levels[min(x * levels.count / width, levels.count - 1)] }
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            if hlg {
                let row = (0..<width).map { UInt16(Int((64 + level(atColumn: $0) * 876).rounded()) << 6) }
                row.withUnsafeBytes { src in
                    for y in 0..<height { memcpy(base + y * stride, src.baseAddress!, width * 2) }
                }
            } else {
                let row = (0..<width).map { UInt8(Int((16 + level(atColumn: $0) * 219).rounded())) }
                row.withUnsafeBytes { src in
                    for y in 0..<height { memcpy(base + y * stride, src.baseAddress!, width) }
                }
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
            for y in 0..<chromaHeight {
                if hlg {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) { row[x] = UInt16(512 << 6) }
                } else {
                    memset(base + y * stride, 128, CVPixelBufferGetWidthOfPlane(buffer, 1) * 2)
                }
            }
        }
    }

    /// Fills a moving horizontal gradient. Rows are identical, so one row is built and copied.
    private static func fill(_ buffer: CVPixelBuffer, frame: Int, hlg: Bool) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)

        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            if hlg {
                var row = [UInt16](repeating: 0, count: width)
                for x in 0..<width {
                    let v = 64 + ((x + frame * 16) % width) * 876 / width  // 10-bit video range 64...940
                    row[x] = UInt16(v << 6)
                }
                row.withUnsafeBytes { src in
                    for y in 0..<height { memcpy(base + y * stride, src.baseAddress!, width * 2) }
                }
            } else {
                var row = [UInt8](repeating: 0, count: width)
                for x in 0..<width { row[x] = UInt8(16 + ((x + frame * 8) % width) * 219 / width) }
                row.withUnsafeBytes { src in
                    for y in 0..<height { memcpy(base + y * stride, src.baseAddress!, width) }
                }
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
            if hlg {
                var row = [UInt16](repeating: 0, count: chromaWidth * 2)
                for x in 0..<chromaWidth {
                    row[2 * x] = UInt16((448 + (x + frame) % 128) << 6)
                    row[2 * x + 1] = UInt16(512 << 6)
                }
                row.withUnsafeBytes { src in
                    for y in 0..<chromaHeight { memcpy(base + y * stride, src.baseAddress!, chromaWidth * 4) }
                }
            } else {
                var row = [UInt8](repeating: 128, count: chromaWidth * 2)
                for x in 0..<chromaWidth { row[2 * x] = UInt8(112 + (x + frame) % 32) }
                row.withUnsafeBytes { src in
                    for y in 0..<chromaHeight { memcpy(base + y * stride, src.baseAddress!, chromaWidth * 2) }
                }
            }
        }
    }

    /// Interleaved Float32 stereo 440 Hz sine at 48 kHz as an LPCM sample buffer.
    fileprivate static func makeAudioBuffer(startSample: Int, count: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw FixtureError.audioBufferFailed(status) }

        var samples = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let v = Float(0.1 * sin(2 * Double.pi * 440 * Double(startSample + i) / Double(sampleRate)))
            samples[2 * i] = v
            samples[2 * i + 1] = v
        }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw FixtureError.audioBufferFailed(status) }
        status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { throw FixtureError.audioBufferFailed(status) }

        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw FixtureError.audioBufferFailed(status) }
        return sample
    }
}
