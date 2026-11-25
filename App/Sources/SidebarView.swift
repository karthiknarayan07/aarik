import LocalLibrary
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        let counts = model.activityCounts
        let badgeCounts = model.library.badgeCounts
        List(selection: $model.selection) {
            Section("Library") {
                DestinationRow(destination: .overview)
                DestinationRow(destination: .photosVideos)
                DestinationRow(destination: .localFiles, count: model.library.items.count)
            }
            if !badgeCounts.isEmpty {
                Section("Media types") {
                    ForEach(MediaBadge.allCases.filter { badgeCounts[$0] != nil }, id: \.self) { badge in
                        DestinationRow(destination: .mediaType(badge), count: badgeCounts[badge] ?? 0)
                    }
                }
            }
            Section("Tools") {
                ForEach(model.tools) { tool in
                    DestinationRow(destination: .tool(tool.id))
                }
                ForEach(model.comingSoonTools) { tool in
                    ComingSoonRow(tool: tool)
                }
            }
            Section("Activity") {
                DestinationRow(destination: .queue, count: counts.queue)
                DestinationRow(destination: .completed, count: counts.completed)
                DestinationRow(destination: .keptAsIs, count: counts.keptAsIs)
                DestinationRow(destination: .failed, count: counts.failed)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}

private struct DestinationRow: View {
    let destination: SidebarDestination
    var count: Int?

    var body: some View {
        Label(destination.title, systemImage: destination.systemImage)
            .badge(count ?? 0)
            .tag(destination)
            .accessibilityLabel(count.map { "\(destination.title), \($0)" } ?? destination.title)
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
