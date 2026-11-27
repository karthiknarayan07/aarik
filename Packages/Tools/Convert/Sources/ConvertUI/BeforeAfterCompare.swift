import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the compare slider's divider is, from 0 (all converted) to 1 (all original), and what moves it. A value
/// type so the drag and the keyboard are tested without a view.
struct CompareSplit: Equatable {
    /// The divider never reaches an edge, so the handle can always be grabbed.
    static let range = 0.02...0.98
    /// A key press moves it this far.
    static let step = 0.05

    private(set) var fraction: Double

    init(fraction: Double = 0.5) {
        self.fraction = fraction.clamped(to: Self.range)
    }

    /// A drag to `x` in a view `width` wide.
    mutating func drag(to x: Double, width: Double) {
        guard width > 0 else { return }
        fraction = (x / width).clamped(to: Self.range)
    }

    mutating func nudge(_ direction: Int) {
        fraction = (fraction + Double(direction) * Self.step).clamped(to: Self.range)
    }

    /// "50 percent original" for VoiceOver.
    var spoken: String { "\(Int((fraction * 100).rounded())) percent original" }

    /// Where in a clip the frames for comparing are taken: the middle, as the first frame is often black.
    static func frameTime(duration: Double) -> Double { duration > 0 ? duration / 2 : 0 }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Reads one frame of a video or image file for the compare view. The files are only read, never changed.
enum CompareFrames {
    /// The upright image (for image files) or middle frame (for video files), at most `maxPixel` on its longer side;
    /// nil when the file can't be read.
    static func frame(of url: URL, maxPixel: Int = 1600) async -> CGImage? {
        guard url.isFileURL else { return nil }
        if isImageURL(url) {
            return imageThumbnail(at: url, maxPixel: maxPixel)
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            return imageThumbnail(at: url, maxPixel: maxPixel)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let time = CMTime(seconds: CompareSplit.frameTime(duration: duration), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .movie)
    }

    private static func imageThumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
