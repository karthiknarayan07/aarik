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
    }
}

/// File → Add files… (⌘O) and Queue → Add to queue (⌘⏎).
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
        CommandMenu("Queue") {
            Button("Add to queue") { model.requestAddSelectionToQueue() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canAddSelectionToQueue)
        }
    }
}
