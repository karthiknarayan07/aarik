import AppCore
import CoreGraphics
import Foundation
import LocalLibrary
import MediaEngine
import UniformTypeIdentifiers

public enum ImagePlanDecision: Sendable, Equatable {
    case convert(
        ImageSpec, outputFormat: ImageOutputFormat, targetPixelSize: CGSize,
        estimatedBytes: Int64, predicted: MetadataReport
    )
    case keptAsIs(reason: String, code: OutcomeCode = .other)
}

/// Estimates size savings and predicts metadata losses before converting images.
public enum ImagePlanner {
    static let alreadySmallReason = "Already small"
    static let savesLittleReason = "Would save less than 10%"
    static let unreadableDimensionsReason = "Couldn't read the image's size"

    public static func decide(
        byteSize: Int64,
        pixelSize: CGSize,
        sourceUTI: String,
        inventory: MetadataInventory,
        spec: ImageSpec,
        isLivePhoto: Bool = false,
        pairedVideoByteSize: Int64? = nil
    ) -> ImagePlanDecision {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return .keptAsIs(reason: unreadableDimensionsReason, code: .unsupportedImage)
        }
        let targetFormat = spec.format.resolvedFormat(sourceUTI: sourceUTI)
        guard targetFormat.isEncodingSupported else {
            return .keptAsIs(
                reason: "This device cannot encode \(targetFormat.title) images", code: .unsupportedImage)
        }
        let sourceConcrete = ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: sourceUTI)
        let isRAW = UTType(sourceUTI)?.conforms(to: .rawImage) ?? false
        let formatChanged = (targetFormat != sourceConcrete) || isRAW || isWebPOrReadOnly(sourceUTI)

        let targetSize = spec.outputPixelSize(for: pixelSize)
        if !formatChanged, spec.targetByteSize == nil, spec.resize != .keepOriginal,
            targetSize == pixelSize, spec.quality >= 0.90
        {
            return .keptAsIs(reason: alreadySmallReason, code: .alreadySmall)
        }

        let estimate = ImageEstimator.estimatedBytes(
            byteSize: byteSize, sourcePixelSize: pixelSize, targetPixelSize: targetSize,
            sourceUTI: sourceUTI, spec: spec, isLivePhoto: isLivePhoto, pairedVideoByteSize: pairedVideoByteSize)

        // When keeping the same format without a target-size override, skip if savings are under 10%,
        // or if keeping same dimensions at near-lossless quality (>= 95%).
        let sameSizeHighQuality =
            !formatChanged && targetSize == pixelSize && spec.quality >= 0.95 && spec.targetByteSize == nil
            && !spec.isLossless && !(isLivePhoto && spec.livePhotoMode == .flattenToStill)
        if sameSizeHighQuality
            || (!formatChanged && spec.targetByteSize == nil && !spec.isLossless
                && !(isLivePhoto && spec.livePhotoMode == .flattenToStill)
                && Double(estimate) > Double(max(1, byteSize)) * 0.90)
        {
            return .keptAsIs(reason: savesLittleReason, code: .savesLittle)
        }

        let report = predicted(
            inventory: inventory, spec: spec, sourceFormat: sourceConcrete, targetFormat: targetFormat,
            formatChanged: formatChanged)
        return .convert(
            spec, outputFormat: targetFormat, targetPixelSize: targetSize,
            estimatedBytes: estimate, predicted: report)
    }

    static func isWebPOrReadOnly(_ utiString: String) -> Bool {
        let lower = utiString.lowercased()
        if lower.contains("webp") || lower.contains("raw") || lower.contains("bmp") || lower.contains("psd")
            || lower.contains("jpeg-xl")
        {
            return true
        }
        guard let uti = UTType(utiString) else { return true }
        return !ImageOutputFormat.supportedWritableIdentifiers.contains(uti.identifier)
    }

    /// Predicts which metadata items are kept, changed, or lost when encoding an image.
    public static func predicted(
        inventory: MetadataInventory,
        spec: ImageSpec,
        sourceFormat: ImageOutputFormat,
        targetFormat: ImageOutputFormat,
        formatChanged: Bool
    ) -> MetadataReport {
        var kept: [MetadataItem] = []
        var changed: [MetadataChange] = []
        var lost: [MetadataItem] = []

        for item in inventory.items {
            if item.key == "img.dimensions" {
                changed.append(
                    MetadataChange(key: item.key, displayName: item.displayName, from: item.value, to: "Resized"))
            } else if item.key == "img.uti", formatChanged {
                changed.append(
                    MetadataChange(
                        key: item.key, displayName: item.displayName, from: sourceFormat.title, to: targetFormat.title))
            } else if isDropped(item: item, targetFormat: targetFormat, spec: spec) {
                lost.append(item)
            } else {
                kept.append(item)
            }
        }
        return MetadataReport(kept: kept, changed: changed, lost: lost)
    }

    private static func isDropped(item: MetadataItem, targetFormat: ImageOutputFormat, spec: ImageSpec) -> Bool {
        switch item.key {
        case "img.raw":
            return true
        case "img.alpha":
            return !targetFormat.supportsAlpha
        case "img.animation":
            return !targetFormat.supportsAnimation
        case "img.depth":
            return !targetFormat.supportsDepthMatte
        case "img.hdrGainMap":
            return !targetFormat.supportsGainMap
        case "img.apple.contentID":
            return spec.livePhotoMode == .flattenToStill || ![.heic, .jpeg].contains(targetFormat)
        default:
            return false
        }
    }
}

public enum ImageEstimator {
    /// Estimates compressed byte size in bytes based on pixel ratio, source/target container ratios, quality curve,
    /// and Live Photo paired video size.
    public static func estimatedBytes(
        byteSize: Int64,
        sourcePixelSize: CGSize,
        targetPixelSize: CGSize,
        sourceUTI: String,
        spec: ImageSpec,
        isLivePhoto: Bool = false,
        pairedVideoByteSize: Int64? = nil
    ) -> Int64 {
        let totalSource = max(Int64(1), byteSize)
        let inPixels = max(1.0, Double(sourcePixelSize.width * sourcePixelSize.height))
        let outPixels = max(1.0, Double(targetPixelSize.width * targetPixelSize.height))
        let pixelRatio = min(1.0, outPixels / inPixels)

        let sourceUTIType = UTType(sourceUTI)
        let isRAW = sourceUTIType?.conforms(to: .rawImage) ?? false
        let isUncompressed =
            (sourceUTIType?.conforms(to: .tiff) == true && !isRAW)
            || sourceUTIType?.conforms(to: .bmp) == true
        let isPNG = sourceUTIType?.conforms(to: .png) == true
        let isJPEG = sourceUTIType?.conforms(to: .jpeg) == true

        let targetFormat = spec.format.resolvedFormat(sourceUTI: sourceUTI)

        var stillEstimate: Double
        if targetFormat == .png || targetFormat == .tiff || (spec.isLossless && targetFormat.supportsLossless) {
            // Lossless output roughly scales with pixel count; JPEG/HEIC -> PNG typically expands per pixel.
            let factor: Double =
                if isRAW { 0.45 } else if isUncompressed { 0.70 } else if isPNG { 0.88 } else { 2.2 }
            stillEstimate = Double(totalSource) * pixelRatio * factor
        } else {
            // Lossy HEIC / JPEG / AVIF
            let formatFactor: Double =
                switch targetFormat {
                case .heic: 0.72
                case .avif: 0.65
                case .jpeg: 1.15
                case .gif: 0.90
                default: 0.80
                }
            let sourceFactor: Double =
                if isRAW { 0.10 } else if isUncompressed { 0.14 } else if isPNG { 0.35 } else if isJPEG { 0.78 } else {
                    0.90
                }
            let qualityFactor = 0.28 + 0.85 * pow(spec.quality, 1.35)
            stillEstimate = Double(totalSource) * pixelRatio * sourceFactor * formatFactor * qualityFactor
        }

        if let cap = spec.targetByteSize {
            stillEstimate = min(stillEstimate, Double(cap))
        }

        var totalEstimate = max(Int64(4_096), Int64(stillEstimate.rounded()))
        if isLivePhoto, spec.livePhotoMode == .preserve, let paired = pairedVideoByteSize, paired > 0 {
            // Paired Live Photo .mov typically shrinks ~40% with HEVC re-encode, adding onto still estimate.
            totalEstimate += Int64((Double(paired) * 0.60).rounded())
        }
        return totalEstimate
    }
}

/// Resolution-by-resolution prediction row used by Conversion Options and Inspector sheets.
public struct ImageResolutionEstimate: Sendable, Equatable, Identifiable {
    public let option: ImageAdvancedOptions.Resolution
    public let outputPixelSize: CGSize
    public let estimatedBytes: Int64
    public let sourceBytes: Int64

    public var id: ImageAdvancedOptions.Resolution { option }
    public var outputMegapixels: Double { (outputPixelSize.width * outputPixelSize.height) / 1_000_000.0 }
}

/// Predicts unavoidable image metadata losses and savings for both local files and Photos assets.
public enum ImageLossCheck {
    public static func losses<ID: Hashable & Sendable>(
        for sources: [(
            id: ID, sourceUTI: String, byteSize: Int64, pixelSize: CGSize, inventory: MetadataInventory,
            isLivePhoto: Bool
        )],
        spec: ImageSpec
    ) -> [PredictedLoss<ID>] {
        sources.compactMap { entry in
            let decision = ImagePlanner.decide(
                byteSize: entry.byteSize, pixelSize: entry.pixelSize, sourceUTI: entry.sourceUTI,
                inventory: entry.inventory, spec: spec, isLivePhoto: entry.isLivePhoto)
            guard case .convert(_, _, _, _, let predicted) = decision else { return nil }
            let lost = predicted.lost
            guard !lost.isEmpty else { return nil }
            return PredictedLoss(
                id: entry.id,
                lost: MetadataNames.plainNames(of: lost),
                keys: lost.map(\.key)
            )
        }
    }

    /// Plain-English loss names for a Photos image asset using asset metadata only (zero downloads).
    public static func photosLostNames(
        isRAW: Bool,
        hasDepth: Bool,
        hasHDR: Bool,
        isLivePhoto: Bool,
        hasAlpha: Bool = false,
        isAnimated: Bool = false,
        sourceUTI: String = "public.heic",
        spec: ImageSpec
    ) -> [String] {
        let targetFormat = spec.format.resolvedFormat(sourceUTI: sourceUTI)
        var names: [String] = []
        if isRAW { names.append("RAW sensor data") }
        if hasAlpha && !targetFormat.supportsAlpha { names.append("Transparency") }
        if isAnimated && !targetFormat.supportsAnimation { names.append("Animation frames") }
        if hasDepth && !targetFormat.supportsDepthMatte { names.append("Portrait depth data") }
        if hasHDR && !targetFormat.supportsGainMap { names.append("HDR Gain Map") }
        if isLivePhoto && (spec.livePhotoMode == .flattenToStill || ![.heic, .jpeg].contains(targetFormat)) {
            names.append("Live Photo motion")
        }
        return names
    }

    public static func resolutionEstimates(
        options: [ImageAdvancedOptions.Resolution] = ImageAdvancedOptions.Resolution.primaryCases,
        sourcePixelSize: CGSize,
        sourceBytes: Int64,
        sourceUTI: String,
        baseSpec: ImageSpec,
        isLivePhoto: Bool = false,
        pairedVideoByteSize: Int64? = nil
    ) -> [ImageResolutionEstimate] {
        options.map { option in
            var copy = baseSpec
            copy.resize = option.resizeMode(customWidth: 2048, customHeight: 2048)
            let outSize = copy.outputPixelSize(for: sourcePixelSize)
            let est = ImageEstimator.estimatedBytes(
                byteSize: sourceBytes, sourcePixelSize: sourcePixelSize, targetPixelSize: outSize,
                sourceUTI: sourceUTI, spec: copy, isLivePhoto: isLivePhoto, pairedVideoByteSize: pairedVideoByteSize)
            return ImageResolutionEstimate(
                option: option, outputPixelSize: outSize, estimatedBytes: est, sourceBytes: sourceBytes)
        }
    }
}

extension LibraryItem {
    /// Best-known UTType identifier for an image item (from inspected metadata, filename extension, or Photos badges).
    public var imageSourceUTI: String {
        if let stored = inventory["img.uti"]?.value, !stored.isEmpty { return stored }
        if let url = fileURL, let uti = UTType(filenameExtension: url.pathExtension) { return uti.identifier }
        if badges.contains(.raw) { return UTType.rawImage.identifier }
        if badges.contains(.transparent) { return UTType.png.identifier }
        if badges.contains(.animated) { return UTType.gif.identifier }
        return photosIdentifier != nil ? UTType.heic.identifier : UTType.jpeg.identifier
    }
}
