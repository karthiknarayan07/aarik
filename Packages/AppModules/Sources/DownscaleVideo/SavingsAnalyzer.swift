import AppCore
import AppUI
import Foundation
import LocalLibrary
import MediaEngine

/// A group of videos that share a quality, a capture year and a library, with what converting them could free.
/// Only aggregates: nothing in here names a video, a place or a person.
public struct SavingsBucket: Sendable, Equatable, Identifiable {
    /// "B1", "B2", ...: the bucket's rank by savings, so it is stable for the same library.
    public let id: String
    public let quality: QualityBucket
    public let year: Int
    public let library: OverviewSummary.Library
    /// Local Files only: the videos that already have a finished conversion are left out of this bucket.
    public let excludesShrunk: Bool
    /// The videos the grid shows for this bucket's filters.
    public let count: Int
    public let bytes: Int64
    /// What converting the available videos would free at the preset it was made with (the Overview's estimate).
    public let couldFree: Int64
    /// The available videos, which "Add These to the Queue" adds.
    public let itemIDs: [UUID]

    public var sourceName: String { library == .photos ? "Photos" : "Local Files" }

    /// "4K60 from 2024"
    public var title: String { "\(quality.title) from \(String(year))" }

    /// "Photos · 120 videos · 38 GB · could free about 22 GB"
    public var detail: String {
        let videos = count == 1 ? "1 video" : "\(count.formatted()) videos"
        return "\(sourceName) · \(videos) · \(ByteFormat.string(bytes)) · could free about "
            + ByteFormat.string(couldFree)
    }
}

/// Groups the library into buckets (quality, capture year, library) and ranks them by what converting could free.
/// Plain Swift, so the Overview can list the biggest groups with or without a language model.
public enum SavingsAnalyzer {
    /// How many buckets a language model is ever asked about.
    public static let promptLimit = 12

    private struct Key: Hashable {
        let quality: QualityBucket
        let year: Int
        let library: OverviewSummary.Library
    }

    private struct Tally {
        var count = 0
        var bytes: Int64 = 0
        var couldFree: Int64 = 0
        var itemIDs: [UUID] = []
    }

    /// Every bucket that could free something, the biggest saving first. `shrunk` are the Local Files videos that
    /// already have a finished conversion: they are left out. Videos with no capture date belong to no bucket.
    /// The estimate is the Overview's own (`OverviewSummary.couldFree`), at each video's preset.
    public static func buckets(
        photos: [LibraryItem], files: [LibraryItem], preset: Preset, overrides: PresetOverrides<UUID> = .init(),
        custom: DownscaleSpec? = nil, shrunk: Set<UUID> = [], calendar: Calendar = .current
    ) -> [SavingsBucket] {
        var tallies: [Key: Tally] = [:]
        for (library, items) in [(OverviewSummary.Library.photos, photos), (.localFiles, files)] {
            for item in items {
                if library == .localFiles, shrunk.contains(item.id) { continue }
                guard let date = item.captureDate else { continue }
                let key = Key(
                    quality: QualityBucket(item: item), year: calendar.component(.year, from: date),
                    library: library)
                var tally = tallies[key, default: Tally()]
                tally.count += 1
                tally.bytes += item.byteSize
                if item.isAvailable {
                    tally.itemIDs.append(item.id)
                    tally.couldFree += OverviewSummary.couldFree(
                        item, preset: overrides.preset(for: item.id, default: preset), custom: custom)
                }
                tallies[key] = tally
            }
        }
        // Ties break on the bucket's own fields, so the order never shuffles between refreshes.
        let ranked = tallies.filter { $0.value.couldFree > 0 }.sorted { lhs, rhs in
            if lhs.value.couldFree != rhs.value.couldFree { return lhs.value.couldFree > rhs.value.couldFree }
            if lhs.key.year != rhs.key.year { return lhs.key.year > rhs.key.year }
            if lhs.key.library != rhs.key.library { return lhs.key.library == .photos }
            return lhs.key.quality < rhs.key.quality
        }
        return ranked.enumerated().map { index, entry in
            SavingsBucket(
                id: "B\(index + 1)", quality: entry.key.quality, year: entry.key.year, library: entry.key.library,
                excludesShrunk: entry.key.library == .localFiles, count: entry.value.count,
                bytes: entry.value.bytes, couldFree: entry.value.couldFree, itemIDs: entry.value.itemIDs)
        }
    }
}
