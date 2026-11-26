import AppUI
import SwiftUI

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(model: delegate.model, updater: delegate.updater)
        }
        // The main window is AppKit's (`MainWindowController`); its menu commands ride on this scene.
        .commands {
            UpdateCommands(updater: delegate.updater)
            ViewCommands(model: delegate.model)
            delegate.module.commands
            HelpCommands()
        }
    }
}

extension KeyChord {
    /// The SwiftUI shortcut for a chord of the command model.
    var keyboardShortcut: KeyboardShortcut {
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        switch key {
        case .character(let character): return KeyboardShortcut(KeyEquivalent(character), modifiers: flags)
        case .return: return KeyboardShortcut(.return, modifiers: flags)
        case .delete: return KeyboardShortcut(.delete, modifiers: flags)
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
/// The sidebar and inspector commands change the model's state directly, so they work in the AppKit-hosted window
/// without relying on SwiftUI's scene focus.
private struct ViewCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(model.sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                model.showMainWindow()
                model.sidebarVisibility = model.sidebarVisibility == .detailOnly ? .all : .detailOnly
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                model.showMainWindow()
                model.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!model.inspectorAvailable)
        }
    }
}

/// Help → links to the project's README, privacy notes, release notes and issues. Without a web address (the
/// Info.plist value is missing) the one item is off, so nothing is a dead end.
private struct HelpCommands: Commands {
    private let links = HelpMenu.links(
        appName: AppModel.displayName,
        homepage: Bundle.main.object(forInfoDictionaryKey: HelpMenu.infoKey) as? String)

    var body: some Commands {
        CommandGroup(replacing: .help) {
            if links.isEmpty {
                Button("\(AppModel.displayName) Help") {}.disabled(true)
            } else {
                ForEach(links, id: \.url) { link in
                    Link(link.title, destination: link.url)
                }
            }
        }
    }
}
