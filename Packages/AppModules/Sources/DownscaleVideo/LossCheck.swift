import AppCore
import Foundation
import MediaEngine

/// One video that converting would strip of some metadata, with what it would lose.
public struct PredictedLoss<ID: Hashable & Sendable>: Sendable, Equatable, Identifiable {
    public let id: ID
    /// Sentence-case names, each once, in inventory order.
    public let lost: [String]

    public init(id: ID, lost: [String]) {
        self.id = id
        self.lost = lost
    }
}

/// What a conversion would lose, before anything runs (spec 8.4: no silent metadata loss).
public enum LossCheck {
    /// The names of what converting with `preset` (or `custom`) would lose; empty when nothing would be lost or
    /// the video would be kept as is. `fallsBackToQuickTime` counts what leaving MPEG-4 for QuickTime loses.
    public static func lostNames(
        byteSize: Int64, inventory: MetadataInventory, preset: Preset, custom: DownscaleSpec? = nil,
        fallsBackToQuickTime: Bool = false
    ) -> [String] {
        let decision = SavingsCalculator.decision(
            byteSize: byteSize, inventory: inventory, preset: preset, custom: custom,
            fallsBackToQuickTime: fallsBackToQuickTime)
        guard case .convert(_, _, let predicted) = decision else { return [] }
        return names(of: predicted.lost)
    }

    /// The videos that would lose something, in the order given; videos that lose nothing are left out. The ones
    /// in `quickTimeFallbacks` (from `quickTimeFallbacks(among:)`) also lose what QuickTime can't keep.
    public static func losses<ID: Hashable & Sendable>(
        for sources: [(id: ID, source: SavingsCalculator.Source)], preset: Preset, custom: DownscaleSpec? = nil,
        quickTimeFallbacks: Set<ID> = []
    ) -> [PredictedLoss<ID>] {
        losses(
            for: sources.map { (id: $0.id, source: $0.source, preset: preset) }, custom: custom,
            quickTimeFallbacks: quickTimeFallbacks)
    }

    /// `losses(for:preset:custom:quickTimeFallbacks:)` with a preset per video (`custom`, when given, wins).
    public static func losses<ID: Hashable & Sendable>(
        for sources: [(id: ID, source: SavingsCalculator.Source, preset: Preset)], custom: DownscaleSpec? = nil,
        quickTimeFallbacks: Set<ID> = []
    ) -> [PredictedLoss<ID>] {
        sources.compactMap { entry in
            let lost = lostNames(
                byteSize: entry.source.byteSize, inventory: entry.source.inventory, preset: entry.preset,
                custom: custom, fallsBackToQuickTime: quickTimeFallbacks.contains(entry.id))
            return lost.isEmpty ? nil : PredictedLoss(id: entry.id, lost: lost)
        }
    }

    /// The files whose output will be QuickTime although they are MPEG-4 (`OutputContainer.decide(for:)`). Reads
    /// each `.mp4` and `.m4v` file's tracks, off the caller's actor; other files are skipped without reading. An
    /// MPEG-4 file that can't be read counts as falling back: showing a loss that doesn't happen is safe, while
    /// a loss left out would make its run keep the original as is.
    @concurrent
    public static func quickTimeFallbacks<ID: Hashable & Sendable>(among files: [(id: ID, url: URL)]) async
        -> Set<ID>
    {
        var result = Set<ID>()
        for file in files {
            // `decide` answers a QuickTime source from its name alone.
            let fallsBack =
                (try? await OutputContainer.decide(for: file.url))?.fallsBackToQuickTime
                ?? (OutputContainer.fileType(for: file.url) != .mov)
            if fallsBack { result.insert(file.id) }
        }
        return result
    }

    /// Readable names for predicted losses: an auxiliary video track and its track metadata (the only track
    /// metadata the planner predicts lost) are one entry, "Cinematic depth data"; everything else uses its display
    /// name. Each name appears once.
    static func names(of items: [MetadataItem]) -> [String] {
        var seen = Set<String>()
        return items.map(name(of:)).filter { seen.insert($0).inserted }
    }

    private static func name(of item: MetadataItem) -> String {
        let isAuxiliaryKind =
            item.key.hasPrefix("track.") && item.key.hasSuffix(".kind") && item.value.hasPrefix("auxv/")
        return isAuxiliaryKind || item.key.hasPrefix("trackmeta.") ? "Cinematic depth data" : item.displayName
    }
}
