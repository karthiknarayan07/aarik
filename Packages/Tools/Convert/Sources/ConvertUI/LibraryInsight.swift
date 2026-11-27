import AppCore
import AppUI
import Convert
import LocalLibrary
import SwiftUI

/// One metadata chip in the inspector: "Dolby Vision", "4K60", "Location".
struct LibraryChip: Equatable, Identifiable {
    let title: String
    let systemImage: String
    let tint: Color
    var id: String { title }
}

/// What the library views say about a video or a set of videos, as plain values: the chips, the savings badge
/// on a tile, the predicted-savings gauge and the storage bar.
enum LibraryInsight {
    /// The quality first ("4K60"), then what the video carries (Dolby Vision, HDR, Cinematic, Slo-mo, Spatial,
    /// Edited), then "Location" when the file has one.
    static func chips(for item: VideoItem) -> [LibraryChip] {
        var chips: [LibraryChip] = []
        let quality = QualityBucket(item: item)
        if quality != .unknown, quality != .other {
            chips.append(LibraryChip(title: quality.title, systemImage: "film", tint: .blue))
        }
        for badge in MediaBadge.ordered(item.badges) where badge != .k4 && badge != .sdr {
            chips.append(LibraryChip(title: badge.displayName, systemImage: badge.systemImage, tint: tint(of: badge)))
        }
        if item.inventory.items.contains(where: { $0.category == .location }) {
            chips.append(LibraryChip(title: "Location", systemImage: "location.fill", tint: .green))
        }
        return chips
    }

    private static func tint(of badge: MediaBadge) -> Color {
        switch badge {
        case .dolbyVision: .purple
        case .hdr: .orange
        case .cinematic: .indigo
        case .sloMo: .teal
        case .spatial: .pink
        case .livePhoto: .yellow
        case .portrait: .mint
        case .raw: .purple
        case .animated: .cyan
        case .transparent: .secondary
        case .edited: .gray
        case .k4, .sdr: .blue
        }
    }

    /// "−58%" for a tile whose video would get smaller at `preset`; nil when it wouldn't, or the file is gone.
    static func savingsBadge(for item: VideoItem, preset: Preset) -> String? {
        guard item.isAvailable, item.byteSize > 0, let after = item.estimatedBytes(preset: preset),
            after < item.byteSize
        else { return nil }
        return ByteFormat.savedPercent(before: item.byteSize, after: after)
    }

    /// What converting these videos would do: their size now and after, and how many it would leave as they are.
    struct Prediction: Equatable {
        var before: Int64
        var after: Int64
        var keptCount: Int
        var count: Int

        var saved: Int64 { max(0, before - after) }
        /// The share saved, from 0 to 1.
        var fraction: Double { before > 0 ? Double(saved) / Double(before) : 0 }
    }

    static func prediction(for items: [VideoItem], preset: (VideoItem) -> Preset) -> Prediction? {
        let available = items.filter { $0.isAvailable && $0.byteSize > 0 }
        guard !available.isEmpty else { return nil }
        var result = Prediction(before: 0, after: 0, keptCount: 0, count: available.count)
        for item in available {
            result.before += item.byteSize
            if let after = item.estimatedBytes(preset: preset(item)), after < item.byteSize {
                result.after += after
            } else {
                result.after += item.byteSize
                result.keptCount += 1
            }
        }
        return result
    }
}

/// A part of the "space you could save" bar.
enum StorageCategory: CaseIterable, Identifiable {
    case hdr4K, sdr4K, hd1080, alreadySmall

    var id: Self { self }

    var title: String {
        switch self {
        case .hdr4K: "4K HDR"
        case .sdr4K: "4K SDR"
        case .hd1080: "1080p"
        case .alreadySmall: "Already Small"
        }
    }

    var tint: Color {
        switch self {
        case .hdr4K: .purple
        case .sdr4K: .blue
        case .hd1080: .teal
        case .alreadySmall: .gray
        }
    }
}

/// Where the space you could save is: a segment per quality for what converting would free, and one for the
/// videos that are already small and stay as they are.
struct StorageBreakdown: Equatable {
    struct Segment: Equatable, Identifiable {
        let category: StorageCategory
        let count: Int
        /// What converting frees, or for Already Small what those videos take.
        let bytes: Int64
        var id: StorageCategory { category }
    }

    let segments: [Segment]

    var couldFree: Int64 { segments.filter { $0.category != .alreadySmall }.reduce(0) { $0 + $1.bytes } }
    var staying: Int64 { segments.first { $0.category == .alreadySmall }?.bytes ?? 0 }
    var total: Int64 { couldFree + staying }
    var isEmpty: Bool { total == 0 }

    /// The segments that have anything in them, in the legend's order.
    var visible: [Segment] { segments.filter { $0.bytes > 0 } }

    /// "4K HDR, 12 GB; 4K SDR, 4 GB" for VoiceOver.
    var spoken: String {
        visible.map { "\($0.category.title), \(ByteFormat.string($0.bytes))" }.joined(separator: "; ")
    }

    static func make(items: [VideoItem], preset: (VideoItem) -> Preset) -> StorageBreakdown {
        build(items.map { (item: $0, preset: preset($0)) })
    }

    /// The same from each item with its preset; free of the main actor, so a big library is worked out off the
    /// UI.
    @concurrent static func make(pairs: [(item: VideoItem, preset: Preset)]) async -> StorageBreakdown {
        build(pairs)
    }

    nonisolated private static func build(_ pairs: [(item: VideoItem, preset: Preset)]) -> StorageBreakdown {
        var counts: [StorageCategory: Int] = [:]
        var bytes: [StorageCategory: Int64] = [:]
        for (item, preset) in pairs where item.isAvailable && item.byteSize > 0 {
            let saved = item.estimatedBytes(preset: preset).map { max(0, item.byteSize - $0) } ?? 0
            let category: StorageCategory
            let size: Int64
            if saved == 0 {
                (category, size) = (.alreadySmall, item.byteSize)
            } else {
                size = saved
                switch QualityBucket(item: item) {
                case .uhd:
                    category = item.badges.contains(.hdr) || item.badges.contains(.dolbyVision) ? .hdr4K : .sdr4K
                default: category = .hd1080
                }
            }
            counts[category, default: 0] += 1
            bytes[category, default: 0] += size
        }
        return StorageBreakdown(
            segments: StorageCategory.allCases.map {
                Segment(category: $0, count: counts[$0] ?? 0, bytes: bytes[$0] ?? 0)
            })
    }
}
