import AppCore
import Foundation
import MediaEngine

/// The Advanced controls: when on, they replace the preset with a custom spec.
public struct AdvancedOptions: Sendable, Equatable {
    public enum Resolution: String, CaseIterable, Sendable, Identifiable {
        case p720, p1080, p1440, keep

        public var id: Self { self }
        public var shortSide: Int? {
            switch self {
            case .p720: 720
            case .p1080: 1080
            case .p1440: 1440
            case .keep: nil
            }
        }
        public var title: String {
            switch self {
            case .p720: "720p"
            case .p1080: "1080p"
            case .p1440: "1440p"
            case .keep: "Keep Original"
            }
        }
        /// Plain-English description shown under each resolution option on touch screens.
        public var summary: String {
            switch self {
            case .p720: "Smallest files · great for messaging and clips"
            case .p1080: "Best balance of sharp video and space saved"
            case .p1440: "Extra detail for iPads, Macs, and TVs"
            case .keep: "Keeps your original width and height"
            }
        }
    }

    public enum FrameRate: String, CaseIterable, Sendable, Identifiable {
        case keep, fps30, fps60

        public var id: Self { self }
        public var cap: Double? {
            switch self {
            case .keep: nil
            case .fps30: 30
            case .fps60: 60
            }
        }
        public var title: String {
            switch self {
            case .keep: "Keep Original"
            case .fps30: "Up to 30 fps"
            case .fps60: "Up to 60 fps"
            }
        }
    }

    /// The lowest bit rate the field accepts, in Mbps.
    public static let minimumMbps = 1.0
    /// Slider bounds on touch UI.
    public static let minimumSliderMbps = 2.0
    public static let maximumSliderMbps = 35.0
    /// The bit rate the field starts at for HEVC at 1080p, in Mbps.
    public static let suggestedHEVCMbps = 10.0
    /// H.264 needs about 1.6x the HEVC bit rate for similar quality.
    public static let h264BitRateFactor = 1.6

    public var isEnabled = false
    /// Switching resolution while the bit rate still holds the previous suggestion updates it to match the new
    /// resolution, leaving a manually adjusted rate untouched.
    public var resolution = Resolution.p1080 {
        didSet {
            if resolution != oldValue, bitRateMbps == Self.suggestedMbps(for: oldValue, codec: codec) {
                bitRateMbps = Self.suggestedMbps(for: resolution, codec: codec)
            }
        }
    }
    public var bitRateMbps = Self.suggestedHEVCMbps
    public var frameRate = FrameRate.keep
    /// Switching format while the bit rate still holds the old format's suggestion moves it to the new one's, so an
    /// untouched field follows the format and a typed value is left alone.
    public var codec = VideoCodec.hevcKeepHDR {
        didSet {
            if codec != oldValue, bitRateMbps == Self.suggestedMbps(for: resolution, codec: oldValue) {
                bitRateMbps = Self.suggestedMbps(for: resolution, codec: codec)
            }
        }
    }

    public init() {}

    /// Builds editable `AdvancedOptions` from a stored job's custom spec, or maps its preset if none was set.
    public init(from custom: DownscaleSpec?, preset: Preset = .balanced) {
        self.init()
        self.isEnabled = true
        if let custom {
            self.resolution =
                switch custom.targetShortSide {
                case 720: .p720
                case 1440: .p1440
                case nil: .keep
                default: .p1080
                }
            self.codec = custom.codec
            self.frameRate =
                switch custom.maxFrameRate {
                case 30?: .fps30
                case 60?: .fps60
                default: .keep
                }
            self.bitRateMbps = max(
                Self.minimumMbps, (Double(custom.averageBitRate) / 1_000_000 * 10).rounded() / 10)
        } else {
            switch preset {
            case .high:
                self.resolution = .keep
                self.bitRateMbps = 18.0
            case .balanced:
                self.resolution = .p1080
                self.bitRateMbps = 10.0
            case .smaller:
                self.resolution = .p720
                self.bitRateMbps = 4.0
            }
        }
    }

    public init(for platform: ToolPlatforms) {
        self.init()
        if platform.contains(.iOS) && !platform.contains(.macOS) { isEnabled = true }
    }

    /// The custom spec, or nil to use the preset.
    public var spec: DownscaleSpec? {
        guard isEnabled else { return nil }
        let mbps = max(bitRateMbps.isFinite ? bitRateMbps : Self.minimumMbps, Self.minimumMbps)
        return DownscaleSpec(
            targetShortSide: resolution.shortSide, averageBitRate: Int((mbps * 1_000_000).rounded()),
            maxFrameRate: frameRate.cap, codec: codec)
    }

    /// Plain-English quality band for a chosen bit rate relative to the resolution's recommended mark.
    public enum BitRateTier: Equatable, Sendable {
        case compact, recommended, highDetail

        public var title: String {
            switch self {
            case .compact: "Compact"
            case .recommended: "Recommended"
            case .highDetail: "High Detail"
            }
        }

        public var advice: String {
            switch self {
            case .compact: "Saves extra space; fast motion or dark scenes may look slightly softer."
            case .recommended: "Sweet spot: looks sharp on phones and TVs while freeing plenty of space."
            case .highDetail: "Keeps extra grain and fast action crisp, with smaller space savings."
            }
        }
    }

    /// Classifies `mbps` relative to the suggested bit rate for `resolution` and `codec`.
    public static func bitRateTier(
        mbps: Double, resolution: Resolution, codec: VideoCodec
    ) -> BitRateTier {
        let suggested = suggestedMbps(for: resolution, codec: codec)
        if mbps < suggested * 0.75 { return .compact }
        if mbps <= suggested * 1.3 { return .recommended }
        return .highDetail
    }

    /// Plain-English sweet-spot guide for choosing bit rate at `resolution` and `codec`.
    public static func bitRateGuide(for resolution: Resolution, codec: VideoCodec) -> String {
        let range: String =
            switch (resolution, codec) {
            case (.p720, .hevcKeepHDR): "3–5 Mbps"
            case (.p720, .h264Compatible): "5–8 Mbps"
            case (.p1080, .hevcKeepHDR): "8–12 Mbps"
            case (.p1080, .h264Compatible): "14–18 Mbps"
            case (.p1440, .hevcKeepHDR): "14–18 Mbps"
            case (.p1440, .h264Compatible): "22–28 Mbps"
            case (.keep, .hevcKeepHDR): "18–24 Mbps"
            case (.keep, .h264Compatible): "28–35 Mbps"
            }
        return "Good range for \(resolution.title) (\(codec == .hevcKeepHDR ? "HEVC" : "H.264")): \(range)."
    }

    /// The bit rate suggested for `resolution` and `codec`, in Mbps.
    public static func suggestedMbps(for resolution: Resolution = .p1080, codec: VideoCodec) -> Double {
        let hevc: Double =
            switch resolution {
            case .p720: 4.0
            case .p1080: suggestedHEVCMbps
            case .p1440: 16.0
            case .keep: 20.0
            }
        switch codec {
        case .hevcKeepHDR: return hevc
        case .h264Compatible: return (hevc * h264BitRateFactor * 10).rounded() / 10
        }
    }
}

extension VideoCodec {
    /// The Format picker's label.
    public var title: String {
        switch self {
        case .hevcKeepHDR: "HEVC (keeps HDR)"
        case .h264Compatible: "H.264 (most compatible)"
        }
    }
}

/// The Save To choice in the inspector.
public struct SaveLocation: Sendable, Equatable {
    public enum Choice: String, CaseIterable, Sendable, Identifiable {
        case nextToOriginal, folder, replace, documents

        public var id: Self { self }
        public var title: String {
            switch self {
            case .nextToOriginal: "Next to Original"
            case .folder: "Folder…"
            case .replace: "Replace Original"
            case .documents: "Documents"
            }
        }
    }

    /// Whether Replace is offered for Files inputs on `platform` (disabled on iOS: no safe system Trash for
    /// arbitrary file providers).
    public static func allowsReplace(for platform: ToolPlatforms = .current) -> Bool {
        !platform.contains(.iOS)
    }

    public static func defaultChoice(for platform: ToolPlatforms = .current) -> Choice {
        platform.contains(.iOS) && !platform.contains(.macOS) ? .documents : .nextToOriginal
    }

    public static func availableChoices(for platform: ToolPlatforms = .current) -> [Choice] {
        platform.contains(.iOS) && !platform.contains(.macOS)
            ? [.documents, .folder]
            : [.nextToOriginal, .folder, .replace]
    }

    public var choice: Choice
    public var folder: URL?
    public var folderBookmark: Data?

    public init(choice: Choice = SaveLocation.defaultChoice()) {
        self.choice = choice
    }

    public init(platform: ToolPlatforms) {
        self.init(choice: Self.defaultChoice(for: platform))
    }

    public init(destination: SaveDestination, platform: ToolPlatforms = .current) {
        switch destination {
        case .nextToOriginal: self.init(choice: .nextToOriginal)
        case .replace:
            self.init(choice: Self.allowsReplace(for: platform) ? .replace : Self.defaultChoice(for: platform))
        case .documents: self.init(choice: .documents)
        case .folder(let bookmark):
            self.init(choice: .folder)
            self.folderBookmark = bookmark
            self.folder = AppSettings.resolve(bookmark)
        }
    }

    /// What a job records; nil while Folder is chosen but no folder has been picked.
    public var destination: SaveDestination? {
        switch choice {
        case .nextToOriginal: .nextToOriginal
        case .replace: .replace
        case .documents: .documents
        case .folder: folderBookmark.map { .folder(bookmark: $0) }
        }
    }

    /// Remembers a picked folder as a bookmark (security-scoped when the system allows it).
    public mutating func setFolder(_ url: URL) throws {
        let bookmark: Data
        if !PlatformBookmark.creation.isEmpty, let scoped = try? url.bookmarkData(options: PlatformBookmark.creation) {
            bookmark = scoped
        } else {
            bookmark = try url.bookmarkData(options: [])
        }
        folder = url
        folderBookmark = bookmark
        choice = .folder
    }
}
