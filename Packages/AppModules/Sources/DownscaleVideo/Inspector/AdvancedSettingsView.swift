import AppUI
import MediaEngine
import SwiftUI

/// Custom resolution, bit rate, frame rate and format, with the planner's verdict for them.
struct AdvancedSettingsView: View {
    @Binding var options: AdvancedOptions
    /// The decision for the one selected video; nil for several.
    let decision: PlanDecision?
    let byteSize: Int64
    /// Some selected video is slo-mo, whose frame rate is always kept.
    var locksFrameRate = false
    /// More than one video is selected.
    var isMultiple = false

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $isExpanded) {
            Toggle("Use Custom Settings", isOn: $options.isEnabled)
            Group {
                Picker("Resolution", selection: $options.resolution) {
                    ForEach(AdvancedOptions.Resolution.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Bit Rate") {
                    HStack(spacing: 4) {
                        TextField(
                            "Bit Rate", value: $options.bitRateMbps, format: .number.precision(.fractionLength(0...1))
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Bit rate in megabits per second")
                        .help("Average video bit rate in Mbps, at least 1")
                        Text("Mbps").foregroundStyle(.secondary)
                    }
                }
                Picker("Frame Rate", selection: $options.frameRate) {
                    ForEach(AdvancedOptions.FrameRate.allCases) { Text($0.title).tag($0) }
                }
                .disabled(locksFrameRate)
                .help(locksFrameRate ? Self.sloMoNote : "Lower the frame rate; it is never raised")
                if locksFrameRate, isMultiple {
                    Text(Self.sloMoNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Format", selection: $options.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("H.264 plays almost everywhere but turns HDR into SDR and drops Dolby Vision")
            }
            .disabled(!options.isEnabled)
            if options.isEnabled, let decision {
                verdict(decision)
            }
        }
        .accessibilityLabel("Advanced settings")
    }

    static let sloMoNote = "Slo-mo clips keep their frame rate"

    @ViewBuilder private func verdict(_ decision: PlanDecision) -> some View {
        switch decision {
        case .convert(_, let estimate, _):
            let saved = ByteFormat.savedPercent(before: byteSize, after: estimate) ?? ""
            StatusLabel(
                "About \(ByteFormat.string(estimate)) (\(saved))", systemImage: "arrow.down.circle", tint: .green)
        case .keptAsIs(let reason, _):
            Label("Kept as is: \(reason)", systemImage: "equal.circle")
                .foregroundStyle(.secondary)
        }
    }
}
