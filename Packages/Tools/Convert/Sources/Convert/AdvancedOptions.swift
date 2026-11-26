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
    /// The bit rate the field starts at for HEVC, in Mbps.
    public static let suggestedHEVCMbps = 10.0
    /// H.264 needs about 1.6x the HEVC bit rate for similar quality.
    public static let h264BitRateFactor = 1.6

    public var isEnabled = false
    public var resolution = Resolution.p1080
    public var bitRateMbps = Self.suggestedHEVCMbps
    public var frameRate = FrameRate.keep
    /// Switching format while the bit rate still holds the old format's suggestion moves it to the new one's, so an
    /// untouched field follows the format and a typed value is left alone.
    public var codec = VideoCodec.hevcKeepHDR {
        didSet {
            if codec != oldValue, bitRateMbps == Self.suggestedMbps(for: oldValue) {
                bitRateMbps = Self.suggestedMbps(for: codec)
            }
        }
    }

    public init() {}

    /// The custom spec, or nil to use the preset.
    public var spec: DownscaleSpec? {
        guard isEnabled else { return nil }
        let mbps = max(bitRateMbps.isFinite ? bitRateMbps : Self.minimumMbps, Self.minimumMbps)
        return DownscaleSpec(
            targetShortSide: resolution.shortSide, averageBitRate: Int((mbps * 1_000_000).rounded()),
            maxFrameRate: frameRate.cap, codec: codec)
    }

    /// The bit rate the field suggests for `codec`, in Mbps.
    static func suggestedMbps(for codec: VideoCodec) -> Double {
        switch codec {
        case .hevcKeepHDR: suggestedHEVCMbps
        case .h264Compatible: (suggestedHEVCMbps * h264BitRateFactor * 10).rounded() / 10
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
