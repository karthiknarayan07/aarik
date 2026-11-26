import AppCore
import AppUI
import MediaEngine
import SwiftUI

/// Original plus a radio group with one option per preset, each with its estimated size and saving. While custom
/// settings are on (they apply to every video) no preset is in use, so the group has no selection and is disabled.
struct PresetEstimateRows: View {
    let byteSize: Int64
    let inventory: MetadataInventory
    @Binding var selection: Preset
    /// Advanced settings are on, so no preset is in use.
    let isCustom: Bool

    private var choice: Binding<Preset?> {
        Binding {
            isCustom ? nil : selection
        } set: { chosen in
            if let chosen { selection = chosen }
        }
    }

    var body: some View {
        LabeledContent("Original", value: ByteFormat.string(byteSize))
        Picker("Quality", selection: choice) {
            ForEach(SavingsCalculator.estimates(byteSize: byteSize, inventory: inventory)) { estimate in
                let option = PresetOption(estimate: estimate, inventory: inventory)
                Text("\(option.name)  \(Text(option.detail).foregroundStyle(.secondary))")
                    .monospacedDigit()
                    .tag(Preset?.some(estimate.preset))
                    .help(option.help(isCustom: isCustom))
                    .accessibilityLabel(option.spoken)
            }
        }
        .pickerStyle(.radioGroup)
        .disabled(isCustom)
    }
}

/// The words of one preset option.
struct PresetOption {
    let estimate: PresetEstimate
    let inventory: MetadataInventory

    /// "Balanced · 1080p"
    var name: String {
        if case .convert(let spec, _, _) = estimate.decision,
            let resolution = SavingsCalculator.resolutionLabel(for: spec, inventory: inventory)
        {
            return "\(estimate.preset.displayName) · \(resolution)"
        }
        return estimate.preset.displayName
    }

    /// "≈ 120 MB (−62%)", or "Kept as is".
    var detail: String {
        guard let bytes = estimate.estimatedBytes else { return "Kept as is" }
        let size = "≈ \(ByteFormat.string(bytes))"
        guard let saved = ByteFormat.savedPercent(before: estimate.byteSize, after: bytes) else { return size }
        return "\(size) (\(saved))"
    }

    func help(isCustom: Bool) -> String {
        if isCustom { return PresetControl(shared: estimate.preset, isCustom: true).help }
        if case .keptAsIs(let reason, _) = estimate.decision { return reason }
        return "Use the \(estimate.preset.displayName) preset"
    }

    /// What VoiceOver reads.
    var spoken: String {
        guard let bytes = estimate.estimatedBytes else {
            let reason: String
            if case .keptAsIs(let text, _) = estimate.decision { reason = ": \(text)" } else { reason = "" }
            return "\(name), kept as is\(reason)"
        }
        let saved = Int(((estimate.savedFraction ?? 0) * 100).rounded())
        return "\(name), about \(ByteFormat.string(bytes)), saves \(saved) percent"
    }
}
