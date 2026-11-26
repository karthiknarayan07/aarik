import AppCore
import AppIntents
import SwiftUI
import WidgetKit

/// Toggles the shared pause flag in the App Group without touching or running any media encoder.
struct SetQueuePausedIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Pause Queue"

    @Parameter(title: "Paused")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if let flagStore = SharedPauseFlagStore() {
            try flagStore.setPaused(value)
        }
        if let snapshotStore = WidgetSnapshotStore(), var snapshot = snapshotStore.load() {
            snapshot.isPaused = value
            snapshot.updatedAt = .now
            if try snapshotStore.saveIfChanged(snapshot) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.summary)
            }
        }
        ControlCenter.shared.reloadControls(ofKind: WidgetKinds.pauseControl)
        return .result()
    }
}

struct QueuePauseProvider: ControlValueProvider, Sendable {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SharedPauseFlagStore()?.isPaused ?? false
    }
}

/// Control Center toggle that pauses or resumes the shrink queue through the App Group.
struct QueuePauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.pauseControl, provider: QueuePauseProvider()) { isPaused in
            ControlWidgetToggle(
                "Pause Queue",
                isOn: isPaused,
                action: SetQueuePausedIntent()
            ) { isOn in
                Label(isOn ? "Paused" : "Running", systemImage: isOn ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Pause Queue")
        .description("Pauses or resumes the shrink queue.")
    }
}
