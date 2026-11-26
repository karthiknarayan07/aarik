import AppCore
import SwiftUI

/// The sidebar: draws whatever sections the hosted tool module lists, through `ToolSidebarModel`.
struct SidebarView<Module: ToolModule>: View {
    let module: Module

    var body: some View {
        let sidebar = ToolSidebarModel(module.sidebar)
        let selection = Binding<Module.Destination?> {
            module.selection
        } set: { newValue in
            if sidebar.accepts(newValue) { module.selection = newValue }
        }
        List(selection: selection) {
            ForEach(sidebar.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        SidebarRow(module: module, row: row)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}

private struct SidebarRow<Module: ToolModule>: View {
    let module: Module
    let row: ToolSidebarModel<Module.Destination>.Row

    var body: some View {
        if row.isSelectable, let destination = row.item.destination {
            available(destination)
        } else {
            unavailable
        }
    }

    private func available(_ destination: Module.Destination) -> some View {
        let item = row.item
        return HStack {
            Label(item.title, systemImage: item.systemImage)
            if let progress = item.progress {
                Spacer()
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
        .badge(item.count ?? 0)
        .tag(destination)
        // The row reads as its title; the count and the running progress are its value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(item.accessibilityValue)
        .modifier(RowContextMenu(module: module, destination: destination))
        .modifier(RowFileDrop(module: module, destination: destination))
    }

    private var unavailable: some View {
        let item = row.item
        return HStack {
            Label(item.title, systemImage: item.systemImage)
            Spacer()
            Text("Soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .disabled(true)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(item.accessibilityValue)
    }
}

/// The module's context menu for a row, only on the rows that have one.
private struct RowContextMenu<Module: ToolModule>: ViewModifier {
    let module: Module
    let destination: Module.Destination

    func body(content: Content) -> some View {
        if module.hasContextMenu(for: destination) {
            content.contextMenu { module.contextMenu(for: destination) }
        } else {
            content
        }
    }
}

/// Files dropped on a row, only on the rows that take them.
private struct RowFileDrop<Module: ToolModule>: ViewModifier {
    let module: Module
    let destination: Module.Destination

    func body(content: Content) -> some View {
        if module.acceptsFileDrop(on: destination) {
            content.dropDestination(for: URL.self) { urls, _ in
                let urls = ImportDropGuard.importable(urls, isInternalDragActive: InternalDrag.isActive)
                return !urls.isEmpty && module.dropFiles(urls, on: destination)
            }
        } else {
            content
        }
    }
}
