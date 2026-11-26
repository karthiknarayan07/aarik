import AppCore
import AppUI
import SwiftUI

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(shell: delegate.shell, updater: delegate.updater)
        }
        // The main window is AppKit's (`MainWindowController`); its menu commands ride on this scene.
        .commands {
            UpdateCommands(updater: delegate.updater)
            ViewCommands(shell: delegate.shell)
            delegate.shell.scene.commands
            HelpCommands()
        }
    }
}

/// App menu → Check for Updates…, below About.
private struct UpdateCommands: Commands {
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

/// View → Show/Hide Sidebar (⌃⌘S) and Show/Hide Inspector (⌥⌘I),
/// The sidebar and inspector commands change the shell's and scene's state directly, so they work in the
/// AppKit-hosted window without relying on SwiftUI's scene focus.
private struct ViewCommands: Commands {
    let shell: MacShell

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(shell.sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                shell.showMainWindow()
                shell.sidebarVisibility = shell.sidebarVisibility == .detailOnly ? .all : .detailOnly
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button(shell.scene.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                shell.showMainWindow()
                shell.scene.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!shell.scene.hasInspector(for: shell.scene.selection))
        }
    }
}

/// Help → links to the project's README, privacy notes, release notes and issues. Without a web address (the
/// Info.plist value is missing) the one item is off, so nothing is a dead end.
private struct HelpCommands: Commands {
    private let links = HelpMenu.links(
        appName: AppInfo.displayName,
        homepage: Bundle.main.object(forInfoDictionaryKey: HelpMenu.infoKey) as? String)

    var body: some Commands {
        CommandGroup(replacing: .help) {
            if links.isEmpty {
                Button("\(AppInfo.displayName) Help") {}.disabled(true)
            } else {
                ForEach(links, id: \.url) { link in
                    Link(link.title, destination: link.url)
                }
            }
        }
    }
}
