import AppCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How an image should be resized before encoding. Never upscales past the source pixel dimensions.
public enum ImageResizeMode: Codable, Sendable, Hashable {
    case keepOriginal
    case megapixels(Double)
    case scalePercent(Int)
    case maxLongSide(Int)
    case customBounds(width: Int, height: Int)

    /// Upright output pixel dimensions for an upright `naturalPixelSize`. Small images are never enlarged.
    public func outputSize(for naturalPixelSize: CGSize) -> CGSize {
        let width = naturalPixelSize.width
        let height = naturalPixelSize.height
        guard width > 0, height > 0 else { return .zero }

        let rawScale: Double
        switch self {
        case .keepOriginal:
            rawScale = 1
        case .megapixels(let targetMP):
            let currentMP = (width * height) / 1_000_000.0
            guard targetMP > 0, currentMP > targetMP else { return rounded(width: width, height: height, scale: 1) }
            rawScale = sqrt(targetMP / currentMP)
        case .scalePercent(let percent):
            guard percent > 0 else { return CGSize(width: 1, height: 1) }
            rawScale = Double(percent) / 100.0
        case .maxLongSide(let maxSide):
            let longSide = max(width, height)
            guard maxSide > 0, longSide > Double(maxSide) else {
                return rounded(width: width, height: height, scale: 1)
            }
            rawScale = Double(maxSide) / longSide
        case .customBounds(let maxWidth, let maxHeight):
            guard maxWidth > 0, maxHeight > 0 else { return CGSize(width: 1, height: 1) }
            rawScale = min(Double(maxWidth) / width, Double(maxHeight) / height)
        }

        let clampedScale = min(1.0, max(0.0, rawScale))
        return rounded(width: width, height: height, scale: clampedScale)
    }

    private func rounded(width: CGFloat, height: CGFloat, scale: Double) -> CGSize {
        CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    public var title: String {
        switch self {
        case .keepOriginal: "Keep Original"
        case .megapixels(let mp):
            if mp == 2 { "2 MP (HD)" } else if mp == 5 { "5 MP (Web)" } else { "\(Int(mp.rounded())) MP" }
        case .scalePercent(let pct): "\(pct)%"
        case .maxLongSide(let px): "\(px) px max"
        case .customBounds(let w, let h): "\(w) × \(h) max"
        }
    }
}

/// Output image container/codec natively writable via `ImageIO`.
public enum ImageOutputFormat: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case keepOriginal
    case heic
    case jpeg
    case png
    case avif
    case tiff
    case gif

    public var id: Self { self }

    /// Explicit formats offered in menus/pickers (all writable formats in addition to `.keepOriginal`).
    public static let concreteFormats: [ImageOutputFormat] = [.heic, .jpeg, .png, .avif, .tiff, .gif]

    public var title: String {
        switch self {
        case .keepOriginal: "Keep Original"
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .gif: "GIF"
        }
    }

    public var fileExtension: String? {
        switch self {
        case .keepOriginal: nil
        case .heic: "heic"
        case .jpeg: "jpg"
        case .png: "png"
        case .avif: "avif"
        case .tiff: "tiff"
        case .gif: "gif"
        }
    }

    public var utType: UTType? {
        switch self {
        case .keepOriginal: nil
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        case .avif: UTType("public.avif")
        case .tiff: .tiff
        case .gif: .gif
        }
    }

    public var supportsLossyQuality: Bool {
        switch self {
        case .heic, .jpeg, .avif: true
        case .keepOriginal, .png, .tiff, .gif: false
        }
    }

    public var supportsLossless: Bool {
        switch self {
        case .png, .tiff, .heic, .avif: true
        case .keepOriginal, .jpeg, .gif: false
        }
    }

    public var supportsAlpha: Bool {
        switch self {
        case .heic, .png, .avif, .tiff, .gif: true
        case .keepOriginal, .jpeg: false
        }
    }

    public var supportsAnimation: Bool {
        switch self {
        case .heic, .png, .gif: true
        case .keepOriginal, .jpeg, .avif, .tiff: false
        }
    }

    public var supportsGainMap: Bool {
        switch self {
        case .heic, .jpeg: true
        default: false
        }
    }

    public var supportsDepthMatte: Bool {
        self == .heic
    }

    /// Resolves `.keepOriginal` to a concrete writable format for a source UTI. RAW, ProRAW, WebP, JXL, BMP, PSD,
    /// and other read-only UTIs resolve safely to `.heic`.
    public func resolvedFormat(sourceUTI: String) -> ImageOutputFormat {
        guard self == .keepOriginal else { return self }
        guard let uti = UTType(sourceUTI) else { return .heic }
        if uti.conforms(to: .heic) || uti.conforms(to: .heif) || uti.identifier == "public.heics" { return .heic }
        if uti.conforms(to: .jpeg) { return .jpeg }
        if uti.conforms(to: .png) { return .png }
        if uti.identifier == "public.avif" || uti.identifier == "public.avis" { return .avif }
        if uti.conforms(to: .tiff) && !uti.conforms(to: .rawImage) { return .tiff }
        if uti.conforms(to: .gif) { return .gif }
        return .heic
    }

    /// Destination UTI used with `CGImageDestinationCreateWithURL`, selecting `public.heics` for animated HEIC.
    public func destinationIdentifier(isAnimated: Bool) -> String? {
        if self == .heic, isAnimated {
            return "public.heics"
        }
        return utType?.identifier
    }

    public static var supportedWritableIdentifiers: Set<String> {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }

    public var isEncodingSupported: Bool {
        guard let id = utType?.identifier else { return true }
        return Self.supportedWritableIdentifiers.contains(id)
    }
}

/// How Live Photos from the Photos library are handled when converting.
public enum LivePhotoMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Convert both the still image and paired short video and save back as a Live Photo.
    case preserve
    /// Convert only the still frame, producing a regular static photo.
    case flattenToStill

    public var id: Self { self }

    public var title: String {
        switch self {
        case .preserve: "Keep Live Photo Motion"
        case .flattenToStill: "Save Still Photo Only"
        }
    }
}

/// Complete settings specifying an image conversion operation.
public struct ImageSpec: Sendable, Hashable, Codable {
    public var resize: ImageResizeMode = .keepOriginal
    public var format: ImageOutputFormat = .keepOriginal
    /// Compression quality `0.05...1.0` for lossy formats (`heic`, `jpeg`, `avif`).
    public var quality: Double = 0.80
    public var isLossless: Bool = false
    /// Optional target maximum output size in bytes. Nil disables target-size search.
    public var targetByteSize: Int64? = nil
    public var livePhotoMode: LivePhotoMode = .preserve

    public init(
        resize: ImageResizeMode = .keepOriginal,
        format: ImageOutputFormat = .keepOriginal,
        quality: Double = 0.80,
        isLossless: Bool = false,
        targetByteSize: Int64? = nil,
        livePhotoMode: LivePhotoMode = .preserve
    ) {
        self.resize = resize
        self.format = format
        self.quality = min(1.0, max(0.05, quality))
        self.isLossless = isLossless
        self.targetByteSize = targetByteSize
        self.livePhotoMode = livePhotoMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resize = try container.decodeIfPresent(ImageResizeMode.self, forKey: .resize) ?? .keepOriginal
        format = try container.decodeIfPresent(ImageOutputFormat.self, forKey: .format) ?? .keepOriginal
        let decodedQuality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? 0.80
        quality = min(1.0, max(0.05, decodedQuality))
        isLossless = try container.decodeIfPresent(Bool.self, forKey: .isLossless) ?? false
        targetByteSize = try container.decodeIfPresent(Int64.self, forKey: .targetByteSize)
        livePhotoMode = try container.decodeIfPresent(LivePhotoMode.self, forKey: .livePhotoMode) ?? .preserve
    }

    public func outputPixelSize(for naturalPixelSize: CGSize) -> CGSize {
        resize.outputSize(for: naturalPixelSize)
    }
}

public enum ImageConversionError: Error, Equatable, Sendable {
    case outputExists
    case sourceAlreadySmall
    case unsupportedSource(String)
    case encoderFailed(String)
    case targetSizeUnreachable(minimumAchieved: Int64, target: Int64)
}

extension ImageConversionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outputExists:
            "A file with the new name already exists, so nothing was saved."
        case .sourceAlreadySmall:
            "The image is already small."
        case .unsupportedSource(let detail):
            detail.isEmpty ? "This kind of image can't be converted yet." : detail
        case .encoderFailed(let detail):
            detail.isEmpty ? "The image couldn't be converted." : detail
        case .targetSizeUnreachable(_, let target):
            "Couldn't shrink the image under \(ByteCountFormatter.string(fromByteCount: target, countStyle: .file)) without going below minimum quality."
        }
    }
}

extension ImageConversionError: OutcomeCoded {
    public var outcomeCode: OutcomeCode {
        switch self {
        case .outputExists: .outputNameTaken
        case .sourceAlreadySmall: .alreadySmall
        case .unsupportedSource: .unsupportedImage
        case .encoderFailed: .conversionFailed
        case .targetSizeUnreachable: .savesLittle
        }
    }
}
