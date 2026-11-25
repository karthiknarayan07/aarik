import AppUI
import SwiftUI

/// Custom resolution, bit rate and frame rate, with the planner's verdict for them.
struct AdvancedSettingsView: View {
    @Binding var options: AdvancedOptions
    /// The decision for the one selected video; nil for several.
    let decision: PlanDecision?
    let byteSize: Int64

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $isExpanded) {
            Toggle("Use custom settings", isOn: $options.isEnabled)
            Group {
                Picker("Resolution", selection: $options.resolution) {
                    ForEach(AdvancedOptions.Resolution.allCases) { Text($0.title).tag($0) }
                }
                TextField(
                    "Bit rate (Mbps)", value: $options.bitRateMbps, format: .number.precision(.fractionLength(0...1))
                )
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Bit rate in megabits per second")
                .help("Average video bit rate in Mbps, at least 1")
                Picker("Frame rate", selection: $options.frameRate) {
                    ForEach(AdvancedOptions.FrameRate.allCases) { Text($0.title).tag($0) }
                }
            }
            .disabled(!options.isEnabled)
            if options.isEnabled, let decision {
                verdict(decision)
            }
        }
        .accessibilityLabel("Advanced settings")
    }

    @ViewBuilder private func verdict(_ decision: PlanDecision) -> some View {
        switch decision {
        case .convert(_, let estimate, _):
            let saved = ByteFormat.savedPercent(before: byteSize, after: estimate) ?? ""
            Label("About \(ByteFormat.string(estimate)) (\(saved))", systemImage: "arrow.down.circle")
                .foregroundStyle(.green)
        case .keptAsIs(let reason):
            Label("Kept as is: \(reason)", systemImage: "equal.circle")
                .foregroundStyle(.secondary)
        }
    }
}
