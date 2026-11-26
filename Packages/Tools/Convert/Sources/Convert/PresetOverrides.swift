import Foundation
import MediaEngine

/// Presets chosen for single videos over the header's default (spec 8.2: global in the header, overridable per
/// video in the inspector). An override lasts while the app runs, whatever the header changes to; choosing the
/// default's own preset drops it, so that video follows the header again.
public struct PresetOverrides<ID: Hashable & Sendable>: Sendable, Hashable {
    private var presets: [ID: Preset] = [:]

    public init() {}

    public var isEmpty: Bool { presets.isEmpty }

    /// The preset `id` converts with: its override, else `default`.
    public func preset(for id: ID, default defaultPreset: Preset) -> Preset {
        presets[id] ?? defaultPreset
    }

    /// The override to point out on a tile: set and not the same as the header's preset.
    public func shownOverride(for id: ID, default defaultPreset: Preset) -> Preset? {
        presets[id].flatMap { $0 == defaultPreset ? nil : $0 }
    }

    /// The preset every video in `ids` converts with; nil when they differ ("Mixed"). `default` for none.
    public func selectionPreset(for ids: some Sequence<ID>, default defaultPreset: Preset) -> Preset? {
        var shared: Preset?
        for id in ids {
            let preset = preset(for: id, default: defaultPreset)
            if let shared, shared != preset { return nil }
            shared = preset
        }
        return shared ?? defaultPreset
    }

    /// Gives every video in `ids` `preset`; for `default`'s own preset, their overrides are dropped instead.
    public mutating func set(_ preset: Preset, for ids: some Sequence<ID>, default defaultPreset: Preset) {
        for id in ids {
            presets[id] = preset == defaultPreset ? nil : preset
        }
    }

    /// Forgets the overrides of videos no longer around.
    public mutating func remove(_ ids: some Sequence<ID>) {
        for id in ids { presets[id] = nil }
    }

    /// What converting `sources` would free, each with its own preset, or all with `custom` when given.
    public func couldFreeBytes(
        for sources: [(id: ID, source: SavingsCalculator.Source)], default defaultPreset: Preset,
        custom: DownscaleSpec? = nil
    ) -> Int64 {
        SavingsCalculator.couldFreeBytes(
            for: sources.map { (source: $0.source, preset: preset(for: $0.id, default: defaultPreset)) },
            custom: custom)
    }
}
