#if os(macOS)
    import AppServices
    import AppUI
    import Convert
    import LocalLibrary
    import SwiftUI

    /// The inspector: nothing selected, one video, or several.
    struct LibraryInspector: View {
        @Bindable var model: ConvertModel

        var body: some View {
            if model.isPhotosPage {
                PhotosInspector(model: model)
            } else {
                localInspector
            }
        }

        @ViewBuilder private var localInspector: some View {
            let items = model.selection?.showsLibrary == true ? model.selectedItems : []
            let images = items.filter(\.isImage)
            let videos = items.filter(\.isVideo)
            if items.isEmpty {
                EmptyState(
                    "No Selection", systemImage: "rectangle.dashed",
                    message: "Select videos or images to see what converting them would save.")
            } else {
                Form {
                    if items.count == 1 {
                        Section {
                            ItemSummaryHeader(item: items[0], thumbnails: model.thumbnailSource)
                        }
                    }
                    if let prediction = LibraryInsight.prediction(
                        for: items, preset: model.effectivePreset(for:), imageSpec: model.imageAdvanced.spec)
                    {
                        Section {
                            PredictedSavingsGauge(
                                prediction: prediction, presetName: model.selectionPreset?.displayName)
                        }
                    }
                    if !images.isEmpty {
                        ImageInspectorSection(
                            options: $model.imageAdvanced,
                            singleItem: items.count == 1 ? items[0] : nil,
                            items: images)
                    }
                    if !videos.isEmpty {
                        ConvertInspector(
                            sources: videos.map(model.inspectorSource(for:)), preset: $model.selectionPreset,
                            advanced: $model.advanced,
                            saveLocation: $model.saveLocation)
                    } else {
                        Section("Save To") {
                            SaveDestinationPicker(location: $model.saveLocation)
                        }
                    }
                    // Add to Queue is in the toolbar; what it would skip is said here.
                    if !model.queueableItems.isEmpty, model.queueableItems.count < model.selectedItems.count {
                        Section {
                        } footer: {
                            Text("Missing files are skipped.")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    /// Poster, name, details and badges for one video.
    struct ItemSummaryHeader: View {
        let item: VideoItem
        let thumbnails: ThumbnailSource
        @State private var image: CGImage?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                poster
                Text(item.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .help(item.fileURL?.path ?? item.name)
                Text(ItemDescription.details(item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                let chips = LibraryInsight.chips(for: item)
                if !chips.isEmpty { ChipRow(chips: chips) }
                if !item.isAvailable {
                    StatusLabel(
                        "The file is missing or its drive isn't connected.", systemImage: "exclamationmark.circle",
                        tint: .orange)
                }
            }
            // Keyed on the whole item: a re-read in place (same path, new file) or a move loads the new poster.
            .task(id: item) {
                image = nil
                guard item.isAvailable else { return }
                image = await thumbnails.image(for: item, maxPixel: 640)
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
                        Image(systemName: item.isImage ? "photo" : "film").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
        }
    }
#endif
