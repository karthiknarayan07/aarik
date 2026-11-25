import AppCore
import AppUI
import MediaEngine
import SwiftUI

/// The Downscale Video part of the inspector, as `Form` sections: quality, Advanced, metadata and Save to.
/// It takes sizes and inventories only, so it knows nothing about where the videos come from.
public struct DownscaleInspector: View {
    let sources: [SavingsCalculator.Source]
    @Binding var preset: Preset
    @Binding var advanced: AdvancedOptions
    @Binding var saveLocation: SaveLocation

    public init(
        sources: [SavingsCalculator.Source], preset: Binding<Preset>, advanced: Binding<AdvancedOptions>,
        saveLocation: Binding<SaveLocation>
    ) {
        self.sources = sources
        self._preset = preset
        self._advanced = advanced
        self._saveLocation = saveLocation
    }

    private var single: SavingsCalculator.Source? { sources.count == 1 ? sources[0] : nil }

    private var decision: PlanDecision? {
        single.map {
            SavingsCalculator.decision(
                byteSize: $0.byteSize, inventory: $0.inventory, preset: preset, custom: advanced.spec)
        }
    }

    /// Picking a preset row switches custom settings off, so the pick takes effect.
    private var presetChoice: Binding<Preset> {
        Binding {
            preset
        } set: {
            preset = $0
            advanced.isEnabled = false
        }
    }

    public var body: some View {
        Section("Quality") {
            if let single {
                PresetEstimateRows(
                    byteSize: single.byteSize, inventory: single.inventory, selection: presetChoice,
                    isCustom: advanced.isEnabled)
            } else {
                SelectionTotals(sources: sources, preset: preset, custom: advanced.spec)
                PresetPicker("Quality preset", selection: $preset, options: Preset.allCases) { $0.displayName }
            }
        }
        Section {
            AdvancedSettingsView(options: $advanced, decision: decision, byteSize: single?.byteSize ?? 0)
        }
        if let decision {
            Section("What happens to metadata") {
                switch decision {
                case .convert(_, _, let predicted):
                    MetadataSummary(report: predicted)
                case .keptAsIs(let reason):
                    Label("Kept as is: \(reason)", systemImage: "equal.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section("Save to") {
            SaveDestinationPicker(location: $saveLocation)
        }
    }
}

/// "Add to Queue · Balanced" for one video, "Add 3 to Queue" for several.
public enum QueueButtonTitle {
    public static func title(count: Int, preset: Preset, isCustom: Bool) -> String {
        if count == 1 { return "Add to Queue · \(isCustom ? "Custom" : preset.displayName)" }
        return "Add \(count) to Queue"
    }
}

/// Totals for a multi-selection.
private struct SelectionTotals: View {
    let sources: [SavingsCalculator.Source]
    let preset: Preset
    let custom: DownscaleSpec?

    var body: some View {
        let total = sources.reduce(Int64(0)) { $0 + $1.byteSize }
        let freed = SavingsCalculator.couldFreeBytes(for: sources, preset: preset, custom: custom)
        LabeledContent("\(sources.count) videos", value: ByteFormat.string(total))
        LabeledContent("Could free about", value: ByteFormat.string(freed))
            .foregroundStyle(.green)
    }
}
