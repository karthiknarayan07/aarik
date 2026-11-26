import AppCore
import AppUI
import MediaEngine
import SwiftUI

/// A selected video as the inspector needs it: size, metadata, whether the file can be converted now, and the
/// preset it converts with (the header's, or its own override).
public struct InspectorSource: Sendable {
    public let byteSize: Int64
    public let inventory: MetadataInventory
    public let isAvailable: Bool
    public let preset: Preset

    public init(byteSize: Int64, inventory: MetadataInventory, isAvailable: Bool, preset: Preset) {
        self.byteSize = byteSize
        self.inventory = inventory
        self.isAvailable = isAvailable
        self.preset = preset
    }

    var savings: SavingsCalculator.Source { (byteSize: byteSize, inventory: inventory) }
}

/// The Downscale Video part of the inspector, as `Form` sections: quality, Advanced, metadata and Save to.
/// It takes sizes and inventories only, so it knows nothing about where the videos come from.
///
/// `preset` is the selection's preset: the one its videos share, nil when they differ ("Mixed"). Choosing one
/// applies to every selected video; the caller decides what that means (spec 8.2: a per-video override).
public struct DownscaleInspector: View {
    let sources: [InspectorSource]
    @Binding var preset: Preset?
    @Binding var advanced: AdvancedOptions
    @Binding var saveLocation: SaveLocation

    public init(
        sources: [InspectorSource], preset: Binding<Preset?>, advanced: Binding<AdvancedOptions>,
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
                byteSize: $0.byteSize, inventory: $0.inventory, preset: $0.preset, custom: advanced.spec)
        }
    }

    private var control: PresetControl { PresetControl(shared: preset, isCustom: advanced.isEnabled) }

    /// The selection's choice. Mixed is a real option, so the picker always has a selection; picking it, or any
    /// preset while custom settings are on, changes nothing.
    private var presetChoice: Binding<PresetControl.Choice> {
        Binding {
            control.selection
        } set: { choice in
            if let chosen = control.preset(choosing: choice) { preset = chosen }
        }
    }

    /// The one video's preset row.
    private func rowChoice(for single: InspectorSource) -> Binding<Preset> {
        Binding {
            single.preset
        } set: { chosen in
            presetChoice.wrappedValue = .preset(chosen)
        }
    }

    public var body: some View {
        Section("Quality") {
            if let single {
                PresetEstimateRows(
                    byteSize: single.byteSize, inventory: single.inventory, selection: rowChoice(for: single),
                    isCustom: advanced.isEnabled)
            } else {
                SelectionTotals(sources: sources, custom: advanced.spec)
                PresetPicker(
                    "Quality preset for the selected videos", selection: presetChoice, options: control.options,
                    label: PresetControl.label
                )
                .disabled(!control.isEnabled)
                .help(control.help)
            }
        }
        Section {
            AdvancedSettingsView(
                options: $advanced, decision: decision, byteSize: single?.byteSize ?? 0,
                locksFrameRate: sources.contains { DownscalePlanner.locksFrameRate($0.inventory) },
                isMultiple: sources.count > 1)
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

    /// The toolbar button's title: short, in Title Case. "Add to Queue", or "Add 3 to Queue" for several.
    public static func toolbarTitle(count: Int) -> String {
        count > 1 ? "Add \(count) to Queue" : "Add to Queue"
    }
}

/// Totals for a multi-selection, over the files that can be converted now (as the queue button counts them), each
/// with its own preset.
private struct SelectionTotals: View {
    let sources: [InspectorSource]
    let custom: DownscaleSpec?

    var body: some View {
        let available = sources.filter(\.isAvailable)
        let total = available.reduce(Int64(0)) { $0 + $1.byteSize }
        let freed = SavingsCalculator.couldFreeBytes(
            for: available.map { (source: $0.savings, preset: $0.preset) }, custom: custom)
        let losing = LossCheck.losses(
            for: available.enumerated().map { (id: $0.offset, source: $0.element.savings, preset: $0.element.preset) },
            custom: custom
        ).count
        let missing = sources.count - available.count
        LabeledContent(available.count == 1 ? "1 video" : "\(available.count) videos", value: ByteFormat.string(total))
        LabeledContent("Could free about", value: ByteFormat.string(freed))
        if losing > 0 {
            StatusLabel(
                losing == 1 ? "1 video will lose metadata" : "\(losing) videos will lose metadata",
                systemImage: "exclamationmark.triangle", tint: .orange)
        }
        if missing > 0 {
            StatusLabel(
                missing == 1 ? "1 missing file is skipped" : "\(missing) missing files are skipped",
                systemImage: "exclamationmark.circle", tint: .orange)
        }
    }
}
