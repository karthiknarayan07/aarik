import CoreVideo
import Foundation
import VideoToolbox

/// Resizes decoded frames with a `VTPixelTransferSession`. By default it keeps the pixel format and every propagated
/// attachment (color primaries, transfer function, matrix, and any dynamic HDR metadata). With `toSDR709` it also
/// converts each frame to 8-bit BT.709 SDR, tone-mapping HDR, for the H.264 output.
///
/// Tone mapping choice: the transfer session itself, with its destination color primaries, transfer function and
/// matrix set to BT.709. This SDK (macOS 27.2) has no `kVTPixelTransferPropertyKey_*` tone-mapping switch, but a
/// session with a BT.709 destination converts an HLG/BT.2020 source with a highlight roll-off rather than a clip.
/// Measured on flat HLG greys at 50 / 75 / 100% signal (8-bit video-range luma out): 99 / 148 / 233, against
/// 99 / 146 / 235 from Core Image's `CIImage` HDR-to-SDR tone mapping and 126 / 181 / 235 for the code values merely
/// relabelled as BT.709 (washed out); HLG light on a 1000-nit display cut off at 100-nit SDR white (clipped) works
/// out to 181 / 235 / 235. It matches
/// the system tone mapping, scales and converts in one pass on the same session, and needs no Core Image context or
/// extra buffer copy, so Core Image is not used. `H264OutputTests.h264ToneMapsHLGInsteadOfClipping` keeps it honest.
final class FrameScaler {
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private let toSDR709: Bool

    /// `pixelFormat` is the destination format; with `toSDR709` it should be an 8-bit one.
    init(width: Int, height: Int, pixelFormat: OSType, toSDR709: Bool = false) throws {
        var session: VTPixelTransferSession?
        var status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard status == noErr, let session else {
            throw DownscaleError.encoderFailed("VTPixelTransferSessionCreate failed: \(status)")
        }
        self.session = session
        self.toSDR709 = toSDR709

        if toSDR709 {
            for (key, value) in Self.sdr709 {
                status = VTSessionSetProperty(session, key: key, value: value)
                guard status == noErr else {
                    VTPixelTransferSessionInvalidate(session)
                    throw DownscaleError.encoderFailed("VTSessionSetProperty \(key) failed: \(status)")
                }
            }
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            VTPixelTransferSessionInvalidate(session)
            throw DownscaleError.encoderFailed("CVPixelBufferPoolCreate failed: \(status)")
        }
        self.pool = pool
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    /// The BT.709 destination: transfer session property → the matching pixel buffer attachment value.
    private static var sdr709: [(CFString, CFString)] {
        [
            (kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
    }

    /// Attachments an SDR frame keeps from its source: they describe the pixels' shape, not their color.
    private static var geometryKeys: [CFString] {
        [
            kCVImageBufferPixelAspectRatioKey, kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
        ]
    }

    func scale(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw DownscaleError.encoderFailed("CVPixelBufferPoolCreatePixelBuffer failed: \(status)")
        }
        status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else {
            throw DownscaleError.encoderFailed("VTPixelTransferSessionTransferImage failed: \(status)")
        }
        if toSDR709 {
            // The transfer carries some source attachments over (the ambient viewing environment, for one). An SDR
            // frame must carry no HDR metadata, so it keeps only its pixel aspect ratio and chroma siting and gets
            // exactly the BT.709 tags.
            CVBufferRemoveAllAttachments(destination)
            for key in Self.geometryKeys {
                if let value = CVBufferCopyAttachment(source, key, nil) {
                    CVBufferSetAttachment(destination, key, value, .shouldPropagate)
                }
            }
            CVBufferSetAttachment(
                destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(
                destination, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(
                destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        } else if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
        }
        return destination
    }
}
