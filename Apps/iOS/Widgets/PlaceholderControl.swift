import AppIntents
import SwiftUI
import WidgetKit

struct PlaceholderControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Pause Queue"

    @Parameter(title: "Paused")
    var value: Bool

    func perform() async throws -> some IntentResult { .result() }
}

/// Placeholder Control Center control. It will flip the queue's paused state through the App Group.
struct PlaceholderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PlaceholderControl") {
            ControlWidgetToggle(
                "Pause Queue",
                isOn: false,
                action: PlaceholderControlIntent()
            ) { isOn in
                Label(isOn ? "Paused" : "Running", systemImage: isOn ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Pause Queue")
        .description("Pauses or resumes the shrink queue.")
    }
}
