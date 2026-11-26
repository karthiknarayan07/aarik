import AppKit
import SwiftUI

/// Settings: how to get the Shrink Videos action into Finder's right-click menu. Finder offers Quick Actions made in
/// Shortcuts, and the action is the app's own, so the row explains the steps and opens Shortcuts.
struct FinderQuickActionSection: View {
    static let shortcutsBundleID = "com.apple.shortcuts"

    var body: some View {
        Section("Finder") {
            LabeledContent {
                Button("Open Shortcuts…") { Self.openShortcuts() }
                    .accessibilityHint("Opens the Shortcuts app")
            } label: {
                Text("Add to Finder")
                Text("In Shortcuts, add the Shrink Videos action, then choose Use as Quick Action ▸ Finder.")
            }
        }
    }

    private static func openShortcuts() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcutsBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
