import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// HEVC Main or Main10, or H.264 High, encoding with a `VTCompressionSession`, so any VideoToolbox property can be
/// set. Compressed frames are collected in decode order and handed out with `takeEncoded()`.
final class VideoEncoder {
    struct Configuration {
        var width: Int
        var height: Int
        var averageBitRate: Int
        /// Hard bit-rate cap over a 1-second window (`DataRateLimits`), in bits per second. Nil leaves it uncapped.
        var maxBitRate: Int? = nil
        var codec: VideoCodec = .hevcKeepHDR
        /// HEVC: Main10 for a 10-bit source, Main for an 8-bit one, so the bit depth is kept. H.264 is always 8-bit.
        var isTenBit: Bool
        var expectedFrameRate: Double?
        /// Raw `kCMFormatDescriptionExtension_*` values copied from the source format description.
        var colorPrimaries: CFString?
        var transferFunction: CFString?
        var matrix: CFString?
        /// Static HDR metadata copied from the source format description (CoreMedia extension bytes).
        var masteringDisplay: CFData?
        var contentLightLevel: CFData?
        /// Mirrors the source's Dolby Vision presence. True (route A): `HDRMetadataInsertionMode = Auto` and
        /// `PreserveDynamicHDRMetadata = true`. False: `HDRMetadataInsertionMode = None`, so a source without Dolby
        /// Vision does not gain it (the encoder default is `Auto`).
        var preservesDolbyVision: Bool

        /// H.264 High, 8-bit BT.709 SDR for frames already tone-mapped to it: no static HDR metadata and no Dolby
        /// Vision, whatever the source had.
        static func h264(width: Int, height: Int, averageBitRate: Int, expectedFrameRate: Double?) -> Configuration {
            Configuration(
                width: width, height: height, averageBitRate: averageBitRate, codec: .h264Compatible, isTenBit: false,
                expectedFrameRate: expectedFrameRate, colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                transferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, masteringDisplay: nil, contentLightLevel: nil,
                preservesDolbyVision: false)
        }
    }

    private let session: VTCompressionSession
    private let collector = EncodedFrameCollector()

    init(_ configuration: Configuration) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(configuration.width), height: Int32(configuration.height),
            codecType: configuration.codec == .h264Compatible ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw DownscaleError.encoderFailed("VTCompressionSessionCreate failed: \(status)")
        }
        self.session = session

        let profile: CFString =
            switch configuration.codec {
            case .h264Compatible: kVTProfileLevel_H264_High_AutoLevel
            case .hevcKeepHDR:
                configuration.isTenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
            }
        var properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, profile),
            (kVTCompressionPropertyKey_AverageBitRate, configuration.averageBitRate as CFNumber),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
        ]
        if let rate = configuration.expectedFrameRate {
            properties.append((kVTCompressionPropertyKey_ExpectedFrameRate, rate as CFNumber))
        }
        if let value = configuration.colorPrimaries {
            properties.append((kVTCompressionPropertyKey_ColorPrimaries, value))
        }
        if let value = configuration.transferFunction {
            properties.append((kVTCompressionPropertyKey_TransferFunction, value))
        }
        if let value = configuration.matrix {
            properties.append((kVTCompressionPropertyKey_YCbCrMatrix, value))
        }
        // Optional properties: a session that reports one unsupported goes on without it. For static HDR metadata the
        // report then shows the item as lost.
        var optional: Set<String> = []
        if let maxBitRate = configuration.maxBitRate, maxBitRate > 0 {
            let bytesPerSecond = max(1, maxBitRate / 8)
            properties.append(
                (kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond as NSNumber, 1.0 as NSNumber] as CFArray))
            optional.insert(kVTCompressionPropertyKey_DataRateLimits as String)
        }
        if let value = configuration.masteringDisplay {
            properties.append((kVTCompressionPropertyKey_MasteringDisplayColorVolume, value))
            optional.insert(kVTCompressionPropertyKey_MasteringDisplayColorVolume as String)
        }
        if let value = configuration.contentLightLevel {
            properties.append((kVTCompressionPropertyKey_ContentLightLevelInfo, value))
            optional.insert(kVTCompressionPropertyKey_ContentLightLevelInfo as String)
        }
        if configuration.codec == .h264Compatible {
            // H.264 never carries Dolby Vision or other dynamic HDR metadata. Its encoder refuses
            // `HDRMetadataInsertionMode` with any value (kVTParameterErr on macOS 27.2), so instead it is told not to
            // preserve dynamic HDR metadata, and FrameScaler hands it frames with nothing but BT.709 color tags.
            // `H264OutputTests.h264FromHLGIsSDR` checks that a Dolby Vision source yields no Dolby Vision.
            properties.append((kVTCompressionPropertyKey_PreserveDynamicHDRMetadata, kCFBooleanFalse))
        } else if configuration.preservesDolbyVision {
            properties.append((kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto))
            properties.append((kVTCompressionPropertyKey_PreserveDynamicHDRMetadata, kCFBooleanTrue))
        } else {
            // An 8-bit or SDR encode inserts no Dolby Vision anyway, so "unsupported" is ignored here. The SDR test
            // covers this path; HLG without Dolby Vision is not testable on macOS 27.2, where every synthetic HLG
            // clip carries Dolby Vision (the encoder adds a dvvC atom on its own).
            properties.append((kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_None))
            optional.insert(kVTCompressionPropertyKey_HDRMetadataInsertionMode as String)
        }
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status == kVTPropertyNotSupportedErr, optional.contains(key as String) { continue }
            guard status == noErr else {
                VTCompressionSessionInvalidate(session)
                throw DownscaleError.encoderFailed("VTSessionSetProperty \(key) failed: \(status)")
            }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else {
            VTCompressionSessionInvalidate(session)
            throw DownscaleError.encoderFailed("VTCompressionSessionPrepareToEncodeFrames: \(prepared)")
        }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Submits one frame. Its compressed output may arrive later; collect it with `takeEncoded()`.
    func encode(_ frame: CVPixelBuffer, presentationTime: CMTime, duration: CMTime) throws {
        let collector = collector
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: presentationTime, duration: duration,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            collector.receive(status: status, sampleBuffer: sampleBuffer)
        }
        guard status == noErr else { throw DownscaleError.encoderFailed("VTCompressionSessionEncodeFrame: \(status)") }
    }

    /// Blocks until every submitted frame has been emitted.
    func completeFrames() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else {
            throw DownscaleError.encoderFailed("VTCompressionSessionCompleteFrames: \(status)")
        }
    }

    /// The frames emitted so far, in decode order. Throws the first encode error, if any.
    func takeEncoded() throws -> [CMSampleBuffer] {
        try collector.take()
    }
}

/// Receives compressed frames on VideoToolbox's callback thread and hands them to the encoding task.
/// `Mutex` makes it `Sendable`; the `@Sendable` output handler captures nothing else.
private final class EncodedFrameCollector: Sendable {
    /// The one unchecked `Sendable` in the downscaler. `CMSampleBuffer` is not marked `Sendable`, but a compressed
    /// frame is complete (data ready, immutable) when VideoToolbox hands it to the output handler, VideoToolbox never
    /// touches it again, and Core Foundation retain/release is thread-safe. The frame moves once, under the lock,
    /// from the callback thread to the encoding task, which is then its only user.
    private struct EncodedFrame: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
    }

    private struct State {
        var frames: [EncodedFrame] = []
        var error: DownscaleError?
    }

    private let state = Mutex(State())

    func receive(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        state.withLock { state in
            if status != noErr {
                if state.error == nil { state.error = .encoderFailed("encoder output: \(status)") }
            } else if let sampleBuffer {
                state.frames.append(EncodedFrame(sampleBuffer: sampleBuffer))
            }
        }
    }

    func take() throws -> [CMSampleBuffer] {
        try state.withLock { state in
            if let error = state.error { throw error }
            defer { state.frames.removeAll() }
            return state.frames.map(\.sampleBuffer)
        }
    }
}
