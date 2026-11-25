import AppUI
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $model.selection, tools: model.tools, comingSoon: model.comingSoonTools)
        } detail: {
            DestinationView(destination: model.selection)
                .inspector(isPresented: $model.isInspectorPresented) {
                    InspectorPlaceholder()
                        .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        InspectorToggle(isPresented: $model.isInspectorPresented)
                    }
                }
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    let tools: [ToolEntry]
    let comingSoon: [ToolEntry]

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                DestinationRow(destination: .overview)
                DestinationRow(destination: .photosVideos)
                DestinationRow(destination: .localFiles)
            }
            Section("Tools") {
                ForEach(tools) { tool in
                    DestinationRow(destination: .tool(tool.id))
                }
                ForEach(comingSoon) { tool in
                    ComingSoonRow(tool: tool)
                }
            }
            Section("Activity") {
                DestinationRow(destination: .queue)
                DestinationRow(destination: .completed)
                DestinationRow(destination: .keptAsIs)
                DestinationRow(destination: .failed)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}

private struct DestinationRow: View {
    let destination: SidebarDestination

    var body: some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
    }
}

private struct ComingSoonRow: View {
    let tool: ToolEntry

    var body: some View {
        HStack {
            Label(tool.title, systemImage: tool.systemImage)
            Spacer()
            Text("Soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .disabled(true)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tool.title), coming soon")
    }
}

private struct DestinationView: View {
    let destination: SidebarDestination?

    var body: some View {
        Group {
            if let destination {
                destination.emptyState
            } else {
                EmptyState("Nothing selected", systemImage: "sidebar.left", message: "Choose a section in the sidebar.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(destination?.title ?? AppModel.displayName)
    }
}

private struct InspectorPlaceholder: View {
    var body: some View {
        EmptyState(
            "No selection",
            systemImage: "sidebar.trailing",
            message: "Select videos to see what converting them would save."
        )
    }
}

private struct InspectorToggle: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(isPresented ? "Hide inspector" : "Show inspector")
        .accessibilityLabel(isPresented ? "Hide inspector" : "Show inspector")
    }
}

extension SidebarDestination {
    fileprivate var title: String {
        switch self {
        case .overview: "Overview"
        case .photosVideos: "Videos"
        case .localFiles: "Local files"
        case .tool(let id): ToolRegistry.tool(withID: id)?.title ?? "Tool"
        case .queue: "Queue"
        case .completed: "Completed"
        case .keptAsIs: "Kept as is"
        case .failed: "Failed"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .overview: "chart.pie"
        case .photosVideos: "photo.on.rectangle"
        case .localFiles: "folder"
        case .tool(let id): ToolRegistry.tool(withID: id)?.systemImage ?? "wrench.and.screwdriver"
        case .queue: "list.bullet.rectangle"
        case .completed: "checkmark.circle"
        case .keptAsIs: "equal.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    @MainActor fileprivate var emptyState: EmptyState {
        switch self {
        case .overview:
            EmptyState(
                "Coming with Photos",
                systemImage: systemImage,
                message: "A summary of the space you could free arrives with Photos library support."
            )
        case .photosVideos:
            EmptyState(
                "Coming with Photos",
                systemImage: systemImage,
                message: "Videos from your Photos library will appear here."
            )
        case .localFiles:
            EmptyState(
                "No files added",
                systemImage: systemImage,
                message: "Add videos or folders to see how much space \(AppModel.displayName) could free."
            )
        case .tool:
            EmptyState(
                title,
                systemImage: systemImage,
                message: "Choose videos in Local files, then add them to the queue."
            )
        case .queue:
            EmptyState(
                "Queue is empty",
                systemImage: systemImage,
                message: "Videos you add to the queue are converted one at a time."
            )
        case .completed:
            EmptyState(
                "Nothing completed yet",
                systemImage: systemImage,
                message: "Finished conversions and the space they saved appear here."
            )
        case .keptAsIs:
            EmptyState(
                "Nothing kept as is",
                systemImage: systemImage,
                message: "Videos that wouldn't get meaningfully smaller are listed here with the reason."
            )
        case .failed:
            EmptyState(
                "No failures",
                systemImage: systemImage,
                message: "Conversions that couldn't finish appear here with the reason and a way to retry."
            )
        }
    }
}
