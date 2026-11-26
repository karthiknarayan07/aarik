import ActivityKit
import SwiftUI
import WidgetKit

struct PlaceholderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
    }
}

/// Placeholder Live Activity. The real lock screen and Dynamic Island layouts replace it in a later task.
struct PlaceholderLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaceholderActivityAttributes.self) { context in
            ProgressView(value: context.state.progress) {
                Label("Shrinking Videos", systemImage: "film.stack")
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ProgressView(value: context.state.progress)
                }
            } compactLeading: {
                Image(systemName: "film.stack")
            } compactTrailing: {
                Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
            } minimal: {
                Image(systemName: "film.stack")
            }
        }
    }
}
