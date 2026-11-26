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
            LibraryCommands(model: delegate.model)
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

/// View → Show/Hide Sidebar (⌃⌘S) and Show/Hide Inspector (⌥⌘I). They change the model's state directly, so they work
/// in the AppKit-hosted window without relying on SwiftUI's scene focus.
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

/// File → Add Files… (⌘O); Edit → Remove from Library; Queue → Add to Queue (⌘⏎) and Pause or Resume Queue (⌘.).
private struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Files…") {
                model.showMainWindow()
                if model.selection?.showsLibrary != true { model.selection = .localFiles }
                model.isImporterPresented = true
            }
            .keyboardShortcut("o")
        }
        CommandGroup(after: .pasteboard) {
            // Only the library entries go; Delete in the grid does the same.
            Button("Remove from Library") {
                model.showMainWindow()
                model.removeSelectionFromLibrary()
            }
            .disabled(!model.canRemoveSelectionFromLibrary)
        }
        CommandMenu("Queue") {
            Button("Add to Queue") {
                model.showMainWindow()
                model.requestAddSelectionToQueue()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canAddSelectionToQueue)
            Button(model.isQueuePaused ? "Resume Queue" : "Pause Queue") {
                model.showMainWindow()
                model.toggleQueuePaused()
            }
            .keyboardShortcut(".", modifiers: .command)
        }
    }
}
