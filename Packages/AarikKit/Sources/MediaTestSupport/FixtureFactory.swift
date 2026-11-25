import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum FixtureHDR: Sendable { case sdr, hlg }

public struct ClipOptions: Sendable {
    public var width = 3840
    public var height = 2160
    public var fps = 30
    public var seconds = 1.0
    public var hdr: FixtureHDR = .hlg
    /// key → string value, keySpace mdta
    public var quickTimeMetadata: [String: String] = [:]
    /// stereo AAC 48 kHz
    public var includeAudio = true
    /// one mebx track, identifier `mdta/com.aarik.test.timed`
    public var includeTimedMetadataTrack = false
    /// 0 or 90 → preferredTransform
    public var rotationDegrees = 0
    public var finderTags: [String] = []
    public var extendedAttributes: [String: Data] = [:]

    public init() {}
}

public enum FixtureError: Error, Sendable {
    case writerFailed(String)
    case pixelBufferFailed(Int32)
    case audioBufferFailed(Int32)
    case metadataFormatFailed(Int32)
    case xattrFailed(String, Int32)
}

public enum FixtureFactory {
    public static let timedMetadataIdentifier = "mdta/com.aarik.test.timed"
    private static let sampleRate = 48_000

    /// Writes a new .mov into a fresh temporary directory and returns its URL.
    public static func makeClip(_ options: ClipOptions = .init()) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "fixture.mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let hlg = options.hdr == .hlg

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
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: hlg
                        ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                        : kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    AVVideoAverageBitRateKey: max(options.width * options.height * 2, 1_000_000),
                ],
            ])
        videoInput.expectsMediaDataInRealTime = false
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
        var audioInput: AVAssetWriterInput?
        if options.includeAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
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
            writer.add(input)
            metadataInput = input
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        }

        // File-level QuickTime metadata
        writer.metadata = options.quickTimeMetadata.sorted { $0.key < $1.key }.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }

        do {
            guard writer.startWriting() else {
                throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: .zero)

            // Timed metadata: one group spanning the clip.
            if let metadataAdaptor, let metadataInput {
                let item = AVMutableMetadataItem()
                item.identifier = AVMetadataIdentifier(rawValue: timedMetadataIdentifier)
                item.dataType = kCMMetadataBaseDataType_UTF8 as String
                item.value = "aarik-timed-0" as NSString
                let range = CMTimeRange(
                    start: .zero, duration: CMTime(seconds: options.seconds, preferredTimescale: 600))
                try await waitUntilReady(metadataInput, writer: writer)
                guard metadataAdaptor.append(AVTimedMetadataGroup(items: [item], timeRange: range)) else {
                    throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "metadata append failed")
                }
                metadataInput.markAsFinished()
            }

            // Frames (and interleaved audio)
            let frameCount = max(1, Int((options.seconds * Double(options.fps)).rounded()))
            var audioSamplesWritten = 0
            for frame in 0..<frameCount {
                try await waitUntilReady(videoInput, writer: writer)
                guard let pool = adaptor.pixelBufferPool else {
                    throw FixtureError.writerFailed("no pixel buffer pool")
                }
                var pixelBuffer: CVPixelBuffer?
                let cv = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard cv == kCVReturnSuccess, let pixelBuffer else { throw FixtureError.pixelBufferFailed(cv) }
                fill(pixelBuffer, frame: frame, hlg: hlg)
                let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(options.fps))
                guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                    throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "video append failed")
                }

                if let audioInput {
                    let target = (frame + 1) * sampleRate / options.fps
                    let count = target - audioSamplesWritten
                    if count > 0 {
                        try await waitUntilReady(audioInput, writer: writer)
                        let buffer = try makeAudioBuffer(startSample: audioSamplesWritten, count: count)
                        guard audioInput.append(buffer) else {
                            throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "audio append failed")
                        }
                        audioSamplesWritten = target
                    }
                }
            }
            videoInput.markAsFinished()
            audioInput?.markAsFinished()

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
        if !options.finderTags.isEmpty {
            var values = URLResourceValues()
            values.tagNames = options.finderTags
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
        for (name, data) in options.extendedAttributes {
            let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
            if result != 0 { throw FixtureError.xattrFailed(name, errno) }
        }
        return url
    }

    // MARK: - Helpers

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled {
                throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "writer \(writer.status)")
            }
            try await Task.sleep(for: .milliseconds(1))
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
    private static func makeAudioBuffer(startSample: Int, count: Int) throws -> CMSampleBuffer {
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
