import AppCore
import SwiftUI

/// The sidebar: draws whatever sections the hosted tool module lists.
struct SidebarView<Module: ToolModule>: View {
    let module: Module

    private var selection: Binding<Module.Destination?> {
        Binding {
            module.selection
        } set: {
            module.selection = $0
        }
    }

    var body: some View {
        List(selection: selection) {
            ForEach(module.sidebar) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        SidebarRow(item: item)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}

private struct SidebarRow<Destination: Hashable & Sendable>: View {
    let item: ToolSidebarItem<Destination>

    var body: some View {
        switch item.availability {
        case .available:
            HStack {
                Label(item.title, systemImage: item.systemImage)
                if let progress = item.progress {
                    Spacer()
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                }
            }
            .badge(item.count ?? 0)
            .tag(item.destination)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityText)
        case .comingSoon:
            HStack {
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
            .accessibilityLabel(item.accessibilityText)
        }
    }
}
