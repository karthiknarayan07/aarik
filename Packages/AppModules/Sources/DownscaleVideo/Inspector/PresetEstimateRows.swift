import AppCore
import AppUI
import MediaEngine
import SwiftUI

/// Original plus one row per preset with its estimated size and saving; click a row to pick that preset.
struct PresetEstimateRows: View {
    let byteSize: Int64
    let inventory: MetadataInventory
    @Binding var selection: Preset
    /// Advanced settings are on, so no preset is in use.
    let isCustom: Bool

    var body: some View {
        LabeledContent("Original", value: ByteFormat.string(byteSize))
        ForEach(SavingsCalculator.estimates(byteSize: byteSize, inventory: inventory)) { estimate in
            PresetRow(
                estimate: estimate, inventory: inventory,
                isSelected: !isCustom && estimate.preset == selection
            ) {
                selection = estimate.preset
            }
        }
    }
}

private struct PresetRow: View {
    let estimate: PresetEstimate
    let inventory: MetadataInventory
    let isSelected: Bool
    let action: () -> Void

    private var name: String {
        if case .convert(let spec, _, _) = estimate.decision,
            let resolution = SavingsCalculator.resolutionLabel(for: spec, inventory: inventory)
        {
            return "\(estimate.preset.displayName) · \(resolution)"
        }
        return estimate.preset.displayName
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(name)
                Spacer()
                if let bytes = estimate.estimatedBytes {
                    Text("≈ \(ByteFormat.string(bytes))").foregroundStyle(.secondary)
                    if let saved = ByteFormat.savedPercent(before: estimate.byteSize, after: bytes) {
                        Text(saved).foregroundStyle(.green).monospacedDigit()
                    }
                } else {
                    Text("Kept as is").foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var helpText: String {
        if case .keptAsIs(let reason) = estimate.decision { return reason }
        return "Use the \(estimate.preset.displayName) preset"
    }

    private var accessibilityText: String {
        guard let bytes = estimate.estimatedBytes else { return "\(name), kept as is: \(helpText)" }
        let saved = Int(((estimate.savedFraction ?? 0) * 100).rounded())
        return "\(name), about \(ByteFormat.string(bytes)), saves \(saved) percent"
    }
}
