import SwiftUI

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            SidebarCommands()
            InspectorCommands()
            LibraryCommands(model: delegate.model)
        }
        Settings {
            SettingsView(model: delegate.model)
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
