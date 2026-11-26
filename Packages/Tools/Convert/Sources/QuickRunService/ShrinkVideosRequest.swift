import Convert
import Foundation
import LocalLibrary
import MediaEngine

// The choices of the Shrink Videos action (the Shortcuts action, the Finder Quick Action, Siri and Spotlight), as
// plain values. The App Intents layer maps its enums onto these one to one, so what each choice means is decided and
// tested here.

/// Whether to shrink 4K to 1080p or compress at the original resolution.
public enum ShrinkMode: Sendable, Equatable, CaseIterable {
    case shrink
    case compress
}

/// How hard to shrink; the presets, under the names the action shows.
public enum ShrinkQuality: Sendable, Equatable, CaseIterable {
    case high, balanced, smaller

    public var preset: Preset {
        switch self {
        case .high: .high
        case .balanced: .balanced
        case .smaller: .smaller
        }
    }

    /// Matching compression preset when `ShrinkMode.compress` is chosen.
    public var compressPreset: CompressPreset {
        switch self {
        case .high: .bestQuality
        case .balanced: .balanced
        case .smaller: .smaller
        }
    }
}

public enum ShrinkFormat: Sendable, Equatable, CaseIterable {
    case hevc, h264

    public var codec: VideoCodec {
        switch self {
        case .hevc: .hevcKeepHDR
        case .h264: .h264Compatible
        }
    }
}

/// Where the copies go. Replace is not a choice: a quick run never replaces.
public enum ShrinkDestination: Sendable, Equatable, CaseIterable {
    case nextToOriginal, folder
}

/// Which videos are meant, by when they were captured. Past periods end now; the others are whole calendar periods.
public enum ShrinkDateRange: Sendable, Equatable, CaseIterable {
    case pastWeek, lastMonth, pastThreeMonths, thisYear, lastYear

    /// From the first to the last second the period covers, as `LibraryBrowser.captureRange` wants it.
    public func range(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        func whole(_ component: Calendar.Component, offset: Int) -> ClosedRange<Date> {
            let anchor = calendar.date(byAdding: component, value: offset, to: now) ?? now
            guard let interval = calendar.dateInterval(of: component, for: anchor) else { return anchor...now }
            return interval.start...interval.end.addingTimeInterval(-1)
        }
        func past(_ component: Calendar.Component, _ count: Int) -> ClosedRange<Date> {
            let back = calendar.date(byAdding: component, value: -count, to: now) ?? now
            return calendar.startOfDay(for: back)...now
        }
        switch self {
        case .pastWeek: return past(.day, 7)
        case .lastMonth: return whole(.month, offset: -1)
        case .pastThreeMonths: return past(.month, 3)
        case .thisYear: return whole(.year, offset: 0)
        case .lastYear: return whole(.year, offset: -1)
        }
    }
}

/// Which videos are meant, by resolution: every frame rate of the resolution (`QualityBucket`).
public enum ShrinkResolution: Sendable, Equatable, CaseIterable {
    case uhd, fullHD

    public var buckets: Set<QualityBucket> {
        switch self {
        case .uhd: Set(FrameRateTier.allCases.map(QualityBucket.uhd))
        case .fullHD: Set(FrameRateTier.allCases.map(QualityBucket.fullHD))
        }
    }

    /// Whether a video of this size has the resolution, for one whose frame rate is unknown (`QualityBucket.unknown`):
    /// the resolution classes are the ones the quality buckets use.
    public func includes(pixelSize: CGSize) -> Bool {
        let resolution = ResolutionClass(shortSide: min(pixelSize.width, pixelSize.height))
        switch self {
        case .uhd: return resolution == .uhd
        case .fullHD: return resolution == .fullHD
        }
    }
}

public enum ShrinkSource: Sendable, Equatable, CaseIterable {
    case localFiles, photos
}

/// Everything one run of the action was given.
public struct ShrinkVideosRequest: Sendable, Equatable {
    /// Videos handed to the action. When there are any, they win over the selection below.
    public var files: [URL] = []
    public var mode: ShrinkMode = .shrink
    public var quality: ShrinkQuality?
    public var format: ShrinkFormat?
    public var destination: ShrinkDestination?
    /// The folder for `destination == .folder`.
    public var folder: URL?
    /// Used only when no `files` are given: which of the app's own videos to shrink.
    public var dateRange: ShrinkDateRange?
    public var resolution: ShrinkResolution?
    public var source: ShrinkSource?
    public var waitForCompletion = true
    /// Where copies go when the videos have no place of their own (a video that came as data only was copied into the
    /// app). It wins over "next to original" and the saved default, never over a folder chosen as the destination.
    public var redirectedFolder: URL?

    public init(
        files: [URL] = [], mode: ShrinkMode = .shrink, quality: ShrinkQuality? = nil, format: ShrinkFormat? = nil,
        destination: ShrinkDestination? = nil, folder: URL? = nil, dateRange: ShrinkDateRange? = nil,
        resolution: ShrinkResolution? = nil, source: ShrinkSource? = nil, waitForCompletion: Bool = true,
        redirectedFolder: URL? = nil
    ) {
        self.redirectedFolder = redirectedFolder
        self.files = files
        self.mode = mode
        self.quality = quality
        self.format = format
        self.destination = destination
        self.folder = folder
        self.dateRange = dateRange
        self.resolution = resolution
        self.source = source
        self.waitForCompletion = waitForCompletion
    }

    /// Whether the request names videos to pick from the app's libraries (a date range, a resolution or a source).
    public var hasSelection: Bool { dateRange != nil || resolution != nil || source != nil }

    /// What the request changes about a quick run. Anything not given stays the saved setting.
    public func overrides() throws -> QuickRunOverrides {
        let kind: ConvertJobKind?
        let codec: VideoCodec?
        switch mode {
        case .shrink:
            kind = nil
            codec = format?.codec
        case .compress:
            if format == .h264 { throw ShrinkVideosError.h264NotForCompress }
            kind = .compress(quality?.compressPreset ?? .balanced)
            codec = nil
        }
        var overrides = QuickRunOverrides(preset: quality?.preset, codec: codec, kind: kind)
        switch destination {
        case .none, .nextToOriginal:
            if let redirectedFolder {
                var location = SaveLocation()
                do { try location.setFolder(redirectedFolder) } catch { throw ShrinkVideosError.folderUnavailable }
                overrides.saveLocation = location
            } else if destination == .nextToOriginal {
                overrides.saveLocation = SaveLocation()
            }
        case .folder:
            guard let folder else { throw ShrinkVideosError.folderNeeded }
            var location = SaveLocation()
            do { try location.setFolder(folder) } catch { throw ShrinkVideosError.folderUnavailable }
            overrides.saveLocation = location
        }
        return overrides
    }
}

/// Why a request can't run; each has a plain message for the action's dialog.
public enum ShrinkVideosError: Error, Sendable, Equatable {
    case folderNeeded
    case folderUnavailable
    case h264NotForPhotos
    case h264NotForCompress
    /// Videos were handed over but none could be read or copied.
    case inputsUnreadable

    public var message: String {
        switch self {
        case .folderNeeded: "Choose a folder to save the videos in, or save them next to the originals."
        case .folderUnavailable: "That folder can't be used. Choose another folder."
        case .inputsUnreadable: "The videos you gave couldn't be read."
        case .h264NotForPhotos: "H.264 isn't available for videos in Photos. Choose HEVC, or shrink Local Files."
        case .h264NotForCompress: "H.264 isn't available when compressing. Choose HEVC, or use Shrink."
        }
    }
}
