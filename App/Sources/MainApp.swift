import AppUI
import LocalLibrary
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
            GoCommands(model: delegate.model)
            LibraryCommands(model: delegate.model)
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

/// A menu item for a command of the pure command model: its title, shortcut and enabled state come from
/// `AppCommands`.
private struct CommandButton: View {
    let model: AppModel
    let id: AppCommandID

    var body: some View {
        let command = AppCommands.command(id, in: model.commandContext)
        Button(command.title) { model.perform(id) }
            .keyboardShortcut(command.shortcut?.keyboardShortcut)
            .disabled(!command.isEnabled)
    }
}

/// View → Show/Hide Sidebar (⌃⌘S) and Show/Hide Inspector (⌥⌘I), then Group By and Sort By for the library pages.
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
            Divider()
            GroupSortMenus(model: model)
        }
    }
}

/// View → Group By and Sort By, as in Finder: a submenu each, with the current choice checked. They act on the
/// library page that is showing and are off on the Activity pages.
private struct GroupSortMenus: View {
    let model: AppModel

    var body: some View {
        let browser = model.activeBrowser
        let grouping = Binding<Grouping>(
            get: { browser?.grouping ?? .none }, set: { browser?.grouping = $0 })
        let sort = Binding<Sort>(
            get: { browser?.sort ?? .biggestFirst }, set: { browser?.sort = $0 })
        Menu("Group By") {
            Picker("Group By", selection: grouping) {
                ForEach(Grouping.menuOrder, id: \.self) { Text($0.menuTitle).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .disabled(browser == nil)
        Menu("Sort By") {
            Picker("Sort By", selection: sort) {
                ForEach(Sort.menuOrder, id: \.self) { Text($0.menuTitle).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .disabled(browser == nil)
    }
}

/// Go → the sections of the sidebar, ⌘1 to ⌘7 in its order.
private struct GoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(AppModel.goDestinations.enumerated()), id: \.offset) { index, destination in
                Button(destination.title) {
                    model.showMainWindow()
                    model.selection = destination
                }
                .keyboardShortcut(SectionShortcuts.chord(at: index)?.keyboardShortcut)
            }
        }
    }
}

/// File → Add Videos… (⌘O); Edit → Remove from Library (⌘⌫); Queue → Add to Queue (⌘⏎), Pause or Resume Queue
/// (⌥⌘P) and Retry All Failed.
private struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            CommandButton(model: model, id: .addVideos)
        }
        CommandGroup(after: .pasteboard) {
            // Only the library entries go; Delete in the grid does the same. Edit → Undo brings them back.
            CommandButton(model: model, id: .removeFromLibrary)
        }
        CommandMenu("Queue") {
            CommandButton(model: model, id: .addToQueue)
            CommandButton(model: model, id: .pauseOrResumeQueue)
            Divider()
            CommandButton(model: model, id: .retryAllFailed)
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
