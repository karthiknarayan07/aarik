import AppCore
import Foundation
import MediaEngine

/// One preset's outcome for one video, as the inspector lists it.
public struct PresetEstimate: Sendable, Equatable, Identifiable {
    public let preset: Preset
    public let byteSize: Int64
    public let decision: PlanDecision

    public var id: Preset { preset }

    /// The estimated output size; nil when the video would be kept as is.
    public var estimatedBytes: Int64? {
        if case .convert(_, let estimate, _) = decision { return estimate }
        return nil
    }

    /// The share of the original saved, from 0 to 1; nil when kept as is.
    public var savedFraction: Double? {
        guard let estimatedBytes, byteSize > 0 else { return nil }
        return 1 - Double(estimatedBytes) / Double(byteSize)
    }
}

/// How much space converting would free. Videos the planner would keep as is count as zero.
public enum SavingsCalculator {
    public typealias Source = (byteSize: Int64, inventory: MetadataInventory)

    /// The planner's decision for a preset, or for `custom` when given.
    public static func decision(
        byteSize: Int64, inventory: MetadataInventory, preset: Preset, custom: DownscaleSpec? = nil
    ) -> PlanDecision {
        let spec = custom ?? preset.spec(for: inventory, byteSize: byteSize)
        return DownscalePlanner.decide(inventory: inventory, byteSize: byteSize, spec: spec)
    }

    /// Sum of `byteSize - estimate` over the videos that would be converted.
    public static func couldFreeBytes(for sources: [Source], preset: Preset, custom: DownscaleSpec? = nil) -> Int64 {
        sources.reduce(into: Int64(0)) { total, source in
            let decision = decision(
                byteSize: source.byteSize, inventory: source.inventory, preset: preset, custom: custom)
            if case .convert(_, let estimate, _) = decision {
                total += max(0, source.byteSize - estimate)
            }
        }
    }

    /// One row per preset, in `Preset.allCases` order.
    public static func estimates(byteSize: Int64, inventory: MetadataInventory) -> [PresetEstimate] {
        Preset.allCases.map { preset in
            PresetEstimate(
                preset: preset, byteSize: byteSize,
                decision: decision(byteSize: byteSize, inventory: inventory, preset: preset))
        }
    }

    /// "4K", "1080p" and so on for what a spec produces from this source.
    public static func resolutionLabel(for spec: DownscaleSpec, inventory: MetadataInventory) -> String? {
        let source = SourceProfile(inventory: inventory, byteSize: 0)
        let size = source.outputSize(shortSide: spec.targetShortSide)
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return nil }
        return shortSide >= 2160 ? "4K" : "\(shortSide)p"
    }
}
