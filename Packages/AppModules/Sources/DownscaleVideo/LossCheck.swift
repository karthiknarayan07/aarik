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
    /// the video would be kept as is.
    public static func lostNames(
        byteSize: Int64, inventory: MetadataInventory, preset: Preset, custom: DownscaleSpec? = nil
    ) -> [String] {
        let decision = SavingsCalculator.decision(
            byteSize: byteSize, inventory: inventory, preset: preset, custom: custom)
        guard case .convert(_, _, let predicted) = decision else { return [] }
        return names(of: predicted.lost)
    }

    /// The videos that would lose something, in the order given; videos that lose nothing are left out.
    public static func losses<ID: Hashable & Sendable>(
        for sources: [(id: ID, source: SavingsCalculator.Source)], preset: Preset, custom: DownscaleSpec? = nil
    ) -> [PredictedLoss<ID>] {
        sources.compactMap { entry in
            let lost = lostNames(
                byteSize: entry.source.byteSize, inventory: entry.source.inventory, preset: preset, custom: custom)
            return lost.isEmpty ? nil : PredictedLoss(id: entry.id, lost: lost)
        }
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
