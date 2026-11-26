import Convert
import AppUI
import LocalLibrary
import SwiftUI

/// The video tool's menu commands: View → Group By and Sort By, the Go menu, File → Add Videos…, Edit → Remove from
/// Library and the Queue menu. They ride on the app's scene through `MacToolScene.commands`.
public struct VideoCommands: Commands {
    let model: ConvertModel

    public init(model: ConvertModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            GroupSortMenus(model: model)
        }
        GoCommands(model: model)
        LibraryCommands(model: model)
    }
}

/// A menu item for a command of the pure command model: its title, shortcut and enabled state come from
/// `AppCommands`.
private struct CommandButton: View {
    let model: ConvertModel
    let id: AppCommandID

    var body: some View {
        let command = AppCommands.command(id, in: model.commandContext)
        Button(command.title) { model.perform(id) }
            .keyboardShortcut(command.shortcut?.keyboardShortcut)
            .disabled(!command.isEnabled)
    }
}

/// View → Group By and Sort By, as in Finder: a submenu each, with the current choice checked. They act on the
/// library page that is showing and are off on the Activity pages.
private struct GroupSortMenus: View {
    let model: ConvertModel

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
    let model: ConvertModel

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(ConvertModel.goDestinations.enumerated()), id: \.offset) { index, destination in
                Button(destination.title) {
                    model.host.showMainWindow()
                    model.selection = destination
                }
                .keyboardShortcut(SectionShortcuts.chord(at: index)?.keyboardShortcut)
            }
        }
    }
}

/// File → Add Videos… (⌘O); Edit → Remove from Library (no shortcut; ⌫ in the grid); Queue → Add to Queue (⌘⏎), Pause or Resume Queue
/// (⌥⌘P) and Retry All Failed.
private struct LibraryCommands: Commands {
    let model: ConvertModel

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
