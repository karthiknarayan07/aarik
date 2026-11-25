import AppCore
import AppUI
import MediaEngine
import SwiftUI

/// A selected video as the inspector needs it: size, metadata, and whether the file can be converted now.
public struct InspectorSource: Sendable {
    public let byteSize: Int64
    public let inventory: MetadataInventory
    public let isAvailable: Bool

    public init(byteSize: Int64, inventory: MetadataInventory, isAvailable: Bool) {
        self.byteSize = byteSize
        self.inventory = inventory
        self.isAvailable = isAvailable
    }

    var savings: SavingsCalculator.Source { (byteSize: byteSize, inventory: inventory) }
}

/// The Downscale Video part of the inspector, as `Form` sections: quality, Advanced, metadata and Save to.
/// It takes sizes and inventories only, so it knows nothing about where the videos come from.
public struct DownscaleInspector: View {
    let sources: [InspectorSource]
    @Binding var preset: Preset
    @Binding var advanced: AdvancedOptions
    @Binding var saveLocation: SaveLocation

    public init(
        sources: [InspectorSource], preset: Binding<Preset>, advanced: Binding<AdvancedOptions>,
        saveLocation: Binding<SaveLocation>
    ) {
        self.sources = sources
        self._preset = preset
        self._advanced = advanced
        self._saveLocation = saveLocation
    }

    private var single: InspectorSource? { sources.count == 1 ? sources[0] : nil }

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

/// "Add to queue · Balanced" for one video, "Add 3 to queue" for several, "Nothing to add" for none.
public enum QueueButtonTitle {
    public static func title(count: Int, preset: Preset, isCustom: Bool) -> String {
        switch count {
        case ..<1: "Nothing to add"
        case 1: "Add to queue · \(isCustom ? "Custom" : preset.displayName)"
        default: "Add \(count) to queue"
        }
    }
}

/// Totals for a multi-selection, over the files that can be converted now (as the queue button counts them).
private struct SelectionTotals: View {
    let sources: [InspectorSource]
    let preset: Preset
    let custom: DownscaleSpec?

    var body: some View {
        let available = sources.filter(\.isAvailable).map(\.savings)
        let total = available.reduce(Int64(0)) { $0 + $1.byteSize }
        let freed = SavingsCalculator.couldFreeBytes(for: available, preset: preset, custom: custom)
        let missing = sources.count - available.count
        LabeledContent(available.count == 1 ? "1 video" : "\(available.count) videos", value: ByteFormat.string(total))
        LabeledContent("Could free about", value: ByteFormat.string(freed))
            .foregroundStyle(.green)
        if missing > 0 {
            Label(
                missing == 1 ? "1 missing file is skipped" : "\(missing) missing files are skipped",
                systemImage: "exclamationmark.circle"
            )
            .foregroundStyle(.orange)
        }
    }
}
