import LocalLibrary
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        let activity = model.activity
        let badgeCounts = model.library.badgeCounts
        List(selection: $model.selection) {
            Section("Library") {
                DestinationRow(destination: .overview)
                DestinationRow(
                    destination: .photosVideos, count: model.photos.hasLoaded ? model.photos.items.count : nil)
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
                DestinationRow(destination: .queue, count: activity.queue, progress: activity.runningProgress)
                DestinationRow(destination: .completed, count: activity.completed)
                DestinationRow(destination: .keptAsIs, count: activity.keptAsIs)
                DestinationRow(destination: .failed, count: activity.failed)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}

private struct DestinationRow: View {
    let destination: SidebarDestination
    var count: Int?
    /// A running job's progress: shows a small ring.
    var progress: Double?

    var body: some View {
        HStack {
            Label(destination.title, systemImage: destination.systemImage)
            if let progress {
                Spacer()
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
        .badge(count ?? 0)
        .tag(destination)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = count.map { "\(destination.title), \($0)" } ?? destination.title
        if let progress { text += ", converting \(Int((progress * 100).rounded()))%" }
        return text
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
