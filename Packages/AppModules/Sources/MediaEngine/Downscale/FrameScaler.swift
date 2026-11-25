import CoreVideo
import Foundation
import VideoToolbox

/// Resizes decoded frames with a `VTPixelTransferSession`, keeping the pixel format and every propagated
/// attachment (color primaries, transfer function, matrix, and any dynamic HDR metadata).
final class FrameScaler {
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int, pixelFormat: OSType) throws {
        var session: VTPixelTransferSession?
        var status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard status == noErr, let session else {
            throw DownscaleError.encoderFailed("VTPixelTransferSessionCreate failed: \(status)")
        }
        self.session = session

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
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
        }
        return destination
    }
}
