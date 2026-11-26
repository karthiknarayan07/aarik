import QuickRunService
import SwiftUI

/// The quick-run entry points' rows in Settings ▸ General. Kept in its own file so the settings screen only adds one
/// line for them.
struct QuickRunSettingsSections: View {
    var body: some View {
        MenuBarSettingsSection()
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

/// The Services item is registered by the app, but macOS keeps new Services turned off until the person turns them
/// on.
private struct ServicesHelpSection: View {
    var body: some View {
        Section("Services") {
            LabeledContent {
                Button("Open System Settings…") { SystemSettingsLink.openKeyboard() }
                    .accessibilityHint("Opens the Keyboard pane of System Settings")
            } label: {
                Text("Shrink Videos in the Services Menu")
                Text(
                    "macOS keeps new Services turned off. To use it from Finder, open Keyboard Shortcuts ▸ Services "
                        + "▸ Files and Folders and turn on Shrink Videos.")
            }
        }
    }
}

private enum SystemSettingsLink {
    /// The Keyboard pane. System Settings has no documented link to Keyboard Shortcuts ▸ Services, so this opens the
    /// pane (its "Keyboard Shortcuts…" button is one click away).
    static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    static func openKeyboard() {
        guard let keyboard else { return }
        NSWorkspace.shared.open(keyboard)
    }
}
