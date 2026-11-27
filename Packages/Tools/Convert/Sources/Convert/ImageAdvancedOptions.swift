import Foundation
import MediaEngine

/// Touch and desktop controls for image conversion, matching `AdvancedOptions` for videos.
public struct ImageAdvancedOptions: Sendable, Equatable {
    public enum Resolution: String, CaseIterable, Sendable, Identifiable {
        case keepOriginal
        case mp24
        case mp12
        case mp5
        case mp2
        case pct75
        case pct50
        case pct25
        case custom

        public var id: Self { self }

        /// Presets listed directly in the primary Resolution picker (`custom` is toggled in More Options).
        public static let primaryCases: [Resolution] = [
            .keepOriginal, .mp24, .mp12, .mp5, .mp2, .pct75, .pct50, .pct25,
        ]

        public var title: String {
            switch self {
            case .keepOriginal: "Keep Original"
            case .mp24: "24 MP"
            case .mp12: "12 MP"
            case .mp5: "5 MP (Web)"
            case .mp2: "2 MP (HD)"
            case .pct75: "75% Scale"
            case .pct50: "50% Scale"
            case .pct25: "25% Scale"
            case .custom: "Custom Dimensions"
            }
        }

        public var summary: String {
            switch self {
            case .keepOriginal: "Keeps original pixels and reduces compression size"
            case .mp24: "Crisp detail for 48 MP ProRAW and camera photos"
            case .mp12: "Standard iPhone detail with big savings"
            case .mp5: "Great for websites, newsletters, and email"
            case .mp2: "Compact HD size for messaging and thumbnails"
            case .pct75: "Reduces width and height by a quarter"
            case .pct50: "Half width and height (a quarter the pixels)"
            case .pct25: "Compact thumbnail size (one-sixteenth pixels)"
            case .custom: "Fit within your chosen width and height"
            }
        }

        public func resizeMode(customWidth: Int, customHeight: Int) -> ImageResizeMode {
            switch self {
            case .keepOriginal: .keepOriginal
            case .mp24: .megapixels(24)
            case .mp12: .megapixels(12)
            case .mp5: .megapixels(5)
            case .mp2: .megapixels(2)
            case .pct75: .scalePercent(75)
            case .pct50: .scalePercent(50)
            case .pct25: .scalePercent(25)
            case .custom: .customBounds(width: max(1, customWidth), height: max(1, customHeight))
            }
        }
    }

    public enum TargetSize: String, CaseIterable, Sendable, Identifiable {
        case off
        case kb200
        case kb500
        case mb1
        case mb2
        case custom

        public var id: Self { self }

        public var title: String {
            switch self {
            case .off: "No Limit"
            case .kb200: "Under 200 KB"
            case .kb500: "Under 500 KB"
            case .mb1: "Under 1 MB"
            case .mb2: "Under 2 MB"
            case .custom: "Custom Limit…"
            }
        }

        public func bytes(customKB: Int) -> Int64? {
            switch self {
            case .off: nil
            case .kb200: 200_000
            case .kb500: 500_000
            case .mb1: 1_000_000
            case .mb2: 2_000_000
            case .custom: Int64(max(10, customKB)) * 1_000
            }
        }
    }

    public enum QualityTier: String, Sendable, CaseIterable {
        case compact
        case recommended
        case highDetail

        public var title: String {
            switch self {
            case .compact: "Compact"
            case .recommended: "Recommended"
            case .highDetail: "High Detail"
            }
        }

        public var advice: String {
            switch self {
            case .compact: "Smallest files — fine for chats and web previews, slight softness up close."
            case .recommended: "Best balance — practically indistinguishable from original on phones and Macs."
            case .highDetail: "Maximum sharpness for printing, editing, and large 5K displays."
            }
        }
    }

    public static let minimumQualityPercent = 20.0
    public static let maximumQualityPercent = 100.0
    public static let defaultQualityPercent = 80.0

    public var resolution: Resolution = .keepOriginal
    public var format: ImageOutputFormat = .keepOriginal
    public var qualityPercent: Double = defaultQualityPercent
    public var isLossless: Bool = false
    public var customMaxWidth: Int = 2048
    public var customMaxHeight: Int = 2048
    public var targetSize: TargetSize = .off
    public var customTargetKB: Int = 500
    public var livePhotoMode: LivePhotoMode = .preserve

    public init() {}

    public init(from spec: ImageSpec) {
        self.init()
        switch spec.resize {
        case .keepOriginal: resolution = .keepOriginal
        case .megapixels(let mp):
            if mp >= 20 {
                resolution = .mp24
            } else if mp >= 9 {
                resolution = .mp12
            } else if mp >= 3.5 {
                resolution = .mp5
            } else {
                resolution = .mp2
            }
        case .scalePercent(let pct):
            if pct >= 65 { resolution = .pct75 } else if pct >= 38 { resolution = .pct50 } else { resolution = .pct25 }
        case .maxLongSide(let edge):
            resolution = .custom
            customMaxWidth = edge
            customMaxHeight = edge
        case .customBounds(let w, let h):
            resolution = .custom
            customMaxWidth = w
            customMaxHeight = h
        }
        format = spec.format
        qualityPercent = (spec.quality * 100).rounded()
        isLossless = spec.isLossless
        livePhotoMode = spec.livePhotoMode
        if let cap = spec.targetByteSize {
            switch cap {
            case 200_000: targetSize = .kb200
            case 500_000: targetSize = .kb500
            case 1_000_000: targetSize = .mb1
            case 2_000_000: targetSize = .mb2
            default:
                targetSize = .custom
                customTargetKB = max(10, Int((Double(cap) / 1_000).rounded()))
            }
        }
    }

    public var spec: ImageSpec {
        ImageSpec(
            resize: resolution.resizeMode(customWidth: customMaxWidth, customHeight: customMaxHeight),
            format: format,
            quality: min(1.0, max(0.05, qualityPercent / 100.0)),
            isLossless: isLossless,
            targetByteSize: targetSize.bytes(customKB: customTargetKB),
            livePhotoMode: livePhotoMode
        )
    }

    public static func qualityTier(percent: Double) -> QualityTier {
        if percent < 65 { return .compact }
        if percent <= 85 { return .recommended }
        return .highDetail
    }

    /// Plain label used when naming output files (e.g. `IMG_1234 (12 MP).heic`).
    public static func label(for spec: ImageSpec) -> String {
        let base: String =
            switch spec.resize {
            case .keepOriginal:
                spec.format == .keepOriginal ? "Compressed" : spec.format.title
            case .megapixels(let mp):
                "\(Int(mp.rounded())) MP"
            case .scalePercent(let pct):
                "\(pct)%"
            case .maxLongSide(let px):
                "\(px)px"
            case .customBounds(let w, let h):
                "\(w)x\(h)"
            }
        return base
    }
}
