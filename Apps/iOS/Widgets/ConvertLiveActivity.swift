import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentations for the whole-queue conversion Live Activity.
struct ConvertLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConvertActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: statusSymbol(for: context.state.status))
                        .foregroundStyle(statusTint(for: context.state.status))
                        .imageScale(.large)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailingMetric(for: context.state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(statusTitle(for: context.state.status))
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.progress)
                            .tint(statusTint(for: context.state.status))
                        if context.state.savedBytes > 0 {
                            Text("Saved \(formattedBytes(context.state.savedBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: statusSymbol(for: context.state.status))
                    .foregroundStyle(statusTint(for: context.state.status))
            } compactTrailing: {
                compactTrailingView(for: context.state)
            } minimal: {
                Image(systemName: statusSymbol(for: context.state.status))
                    .foregroundStyle(statusTint(for: context.state.status))
            }
        }
    }

    @ViewBuilder
    private func trailingMetric(for state: ConvertActivityAttributes.ContentState) -> some View {
        switch state.status {
        case .finished:
            Text("Done")
        case .running, .waitingThermal, .waitingBattery:
            Text("\(state.itemsRemaining) left")
        }
    }

    @ViewBuilder
    private func compactTrailingView(for state: ConvertActivityAttributes.ContentState) -> some View {
        switch state.status {
        case .finished:
            Image(systemName: "checkmark")
        case .waitingThermal, .waitingBattery:
            Image(systemName: "pause.fill")
        case .running:
            Text(state.progress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
    }

    private func statusTitle(for status: ConvertActivityAttributes.ContentState.Status) -> String {
        switch status {
        case .running: "Shrinking Videos"
        case .waitingThermal: "Paused to Cool Down"
        case .waitingBattery: "Paused: Battery Low"
        case .finished: "Finished Shrinking"
        }
    }

    private func statusSymbol(for status: ConvertActivityAttributes.ContentState.Status) -> String {
        switch status {
        case .running: "film.stack"
        case .waitingThermal: "thermometer.high"
        case .waitingBattery: "battery.25"
        case .finished: "checkmark.circle.fill"
        }
    }

    private func statusTint(for status: ConvertActivityAttributes.ContentState.Status) -> Color {
        switch status {
        case .running: .accentColor
        case .waitingThermal, .waitingBattery: .orange
        case .finished: .green
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct LockScreenView: View {
    let state: ConvertActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(titleText, systemImage: symbolName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(countText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: state.progress)
                .tint(progressTint)

            HStack {
                if state.savedBytes > 0 {
                    Text("Saved \(ByteCountFormatter.string(fromByteCount: state.savedBytes, countStyle: .file))")
                } else {
                    Text(subtitleText)
                }
                Spacer()
                if state.status != .finished {
                    Text(state.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var titleText: String {
        switch state.status {
        case .running: "Shrinking Videos"
        case .waitingThermal: "Paused to Cool Down"
        case .waitingBattery: "Paused: Battery Low"
        case .finished: "Finished Shrinking"
        }
    }

    private var subtitleText: String {
        switch state.status {
        case .running: "Processing queue"
        case .waitingThermal: "Waiting for device temperature to drop"
        case .waitingBattery: "Waiting for charger or higher battery"
        case .finished: "All videos processed"
        }
    }

    private var countText: String {
        switch state.status {
        case .finished:
            state.totalItems == 1 ? "1 video" : "\(state.totalItems) videos"
        case .running, .waitingThermal, .waitingBattery:
            "\(state.itemsRemaining) left"
        }
    }

    private var symbolName: String {
        switch state.status {
        case .running: "film.stack"
        case .waitingThermal: "thermometer.high"
        case .waitingBattery: "battery.25"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var progressTint: Color {
        switch state.status {
        case .running: .accentColor
        case .waitingThermal, .waitingBattery: .orange
        case .finished: .green
        }
    }
}
