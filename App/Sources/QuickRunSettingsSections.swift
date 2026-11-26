import AppKit
import QuickRunService
import SwiftUI

/// The quick-run entry points' rows in Settings ▸ General (next to `FinderQuickActionSection`): the menu bar item,
/// notifications and Services. Kept in its own file so the settings screen only adds one line for them.
struct QuickRunSettingsSections: View {
    var body: some View {
        MenuBarSettingsSection()
        NotificationsHelpSection()
        ServicesHelpSection()
    }
}

/// "Show in Menu Bar": the status item appears or disappears as soon as it changes.
private struct MenuBarSettingsSection: View {
    @AppStorage(MenuBarPreference.key) private var showsInMenuBar = true

    var body: some View {
        Section("Menu Bar") {
            Toggle(isOn: $showsInMenuBar) {
                Text("Show in Menu Bar")
                Text("Shows the queue's progress and lets you drop videos on the icon to convert them.")
            }
        }
    }
}

/// A quick run ends with one notification. Whether it is allowed is the person's choice in System Settings, which the
/// row opens at the app's own entry when the system knows it.
private struct NotificationsHelpSection: View {
    var body: some View {
        Section("Notifications") {
            LabeledContent {
                Button("Open Notification Settings…") {
                    if let url = SystemSettingsPane.notifications(bundleIdentifier: Bundle.main.bundleIdentifier) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityHint("Opens the Notifications pane of System Settings")
            } label: {
                Text("Quick Run Notifications")
                Text(
                    "A quick run says how it went in one notification. It stays quiet while the window is in front, or, for a run started from the menu bar, while its panel is open. "
                        + "If none arrive, allow notifications for the app in System Settings.")
            }
        }
    }
}

/// The Services item is registered by the app, but macOS keeps new Services turned off until the person turns them
/// on.
private struct ServicesHelpSection: View {
    var body: some View {
        Section("Services") {
            LabeledContent {
                Button("Open System Settings…") {
                    if let url = SystemSettingsPane.keyboard { NSWorkspace.shared.open(url) }
                }
                .accessibilityHint("Opens the Keyboard pane of System Settings")
            } label: {
                Text("Shrink Videos in the Services Menu")
                Text(
                    "macOS keeps new Services turned off. In System Settings, choose Keyboard ▸ Keyboard Shortcuts ▸ "
                        + "Services ▸ Files and Folders and turn on Shrink Videos.")
            }
        }
    }
}
