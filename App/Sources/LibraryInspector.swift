import AppUI
import DownscaleVideo
import LocalLibrary
import SwiftUI

/// The inspector: nothing selected, one video, or several.
struct LibraryInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        let items = model.selection?.showsLibrary == true ? model.selectedItems : []
        if items.isEmpty {
            EmptyState(
                "No selection", systemImage: "rectangle.dashed",
                message: "Select videos to see what converting them would save.")
        } else {
            Form {
                if items.count == 1 {
                    Section {
                        ItemSummaryHeader(item: items[0], thumbnails: model.thumbnails)
                    }
                }
                DownscaleInspector(
                    sources: items.map(\.inspectorSource), preset: $model.preset, advanced: $model.advanced,
                    saveLocation: $model.saveLocation)
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                QueueButton(model: model)
            }
        }
    }
}

private struct QueueButton: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Button {
                model.requestAddSelectionToQueue()
            } label: {
                Label(model.addToQueueTitle, systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canAddSelectionToQueue)
            .help("Add to the queue (⌘⏎)")
            if !model.queueableItems.isEmpty, model.queueableItems.count < model.selectedItems.count {
                Text("Missing files are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

/// Poster, name, details and badges for one video.
private struct ItemSummaryHeader: View {
    let item: VideoItem
    let thumbnails: ThumbnailCache
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            poster
            Text(item.url.lastPathComponent)
                .font(.headline)
                .textSelection(.enabled)
                .help(item.url.path)
            Text(ItemDescription.details(item))
                .font(.callout)
                .foregroundStyle(.secondary)
            if !item.badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(MediaBadge.ordered(item.badges), id: \.self) { badge in
                        Text(badge.displayName)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !item.isAvailable {
                Label("The file is missing or its drive isn't connected.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .task(id: item.url) {
            image = nil
            guard item.isAvailable else { return }
            image = await thumbnails.thumbnail(for: item.url, maxPixel: 640)
        }
    }

    private var poster: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}
