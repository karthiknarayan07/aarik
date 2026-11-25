import SwiftUI

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            UpdateCommands(updater: delegate.updater)
            SidebarCommands()
            InspectorCommands()
            LibraryCommands(model: delegate.model)
        }
        Settings {
            SettingsView(model: delegate.model, updater: delegate.updater)
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

/// File → Add files… (⌘O); Edit → Remove from library; Queue → Add to queue (⌘⏎) and Pause or Resume queue (⌘.).
private struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add files…") {
                if model.selection?.showsLibrary != true { model.selection = .localFiles }
                model.isImporterPresented = true
            }
            .keyboardShortcut("o")
        }
        CommandGroup(after: .pasteboard) {
            // Only the library entries go; Delete in the grid does the same.
            Button("Remove from library") { model.removeSelectionFromLibrary() }
                .disabled(!model.canRemoveSelectionFromLibrary)
        }
        CommandMenu("Queue") {
            Button("Add to queue") { model.requestAddSelectionToQueue() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canAddSelectionToQueue)
            Button(model.isQueuePaused ? "Resume queue" : "Pause queue") { model.toggleQueuePaused() }
                .keyboardShortcut(".", modifiers: .command)
        }
    }
}
