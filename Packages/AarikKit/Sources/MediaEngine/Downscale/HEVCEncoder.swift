import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// HEVC Main10 encoding with a `VTCompressionSession`, so any VideoToolbox property can be set.
/// Compressed frames are collected in decode order and handed out with `takeEncoded()`.
final class HEVCEncoder {
    struct Configuration {
        var width: Int
        var height: Int
        var averageBitRate: Int
        var expectedFrameRate: Double?
        /// Raw `kCMFormatDescriptionExtension_*` values copied from the source format description.
        var colorPrimaries: CFString?
        var transferFunction: CFString?
        var matrix: CFString?
        /// Dolby Vision route A: `HDRMetadataInsertionMode = Auto` and `PreserveDynamicHDRMetadata = true`.
        /// Set only for a Dolby Vision HLG source.
        var preservesDolbyVision: Bool
    }

    private let session: VTCompressionSession
    private let collector = EncodedFrameCollector()

    init(_ configuration: Configuration) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(configuration.width), height: Int32(configuration.height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw DownscaleError.encoderFailed("VTCompressionSessionCreate failed: \(status)")
        }
        self.session = session

        var properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel),
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
        if configuration.preservesDolbyVision {
            properties.append((kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto))
            properties.append((kVTCompressionPropertyKey_PreserveDynamicHDRMetadata, kCFBooleanTrue))
        }
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                VTCompressionSessionInvalidate(session)
                throw DownscaleError.encoderFailed("VTSessionSetProperty \(key) failed: \(status)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
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
