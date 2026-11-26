#if os(iOS)
    import AppServices
    import AppUI
    import Convert
    import LocalLibrary
    import SwiftUI
    import UniformTypeIdentifiers

    /// iOS inspector for both Photos and Local Files selections. Adapts cleanly for the compact sheet and the
    /// regular side column.
    struct IOSLibraryInspector: View {
        @Bindable var model: ConvertModel
        let isCompact: Bool
        let dismiss: () -> Void

        var body: some View {
            if isCompact {
                NavigationStack {
                    content
                        .navigationTitle("Conversion Options")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done", action: dismiss)
                            }
                            if model.canAddSelectionToQueue {
                                ToolbarItem(placement: .confirmationAction) {
                                    Menu("Add") {
                                        Button("Add to Queue", systemImage: "text.badge.plus") {
                                            dismiss()
                                            model.requestAddSelectionToQueue(startsQueue: false)
                                        }
                                        Button("Convert Now", systemImage: "play.fill") {
                                            dismiss()
                                            model.convertSelectionNow()
                                        }
                                    }
                                    .buttonStyle(.glassProminent)
                                }
                            }
                        }
                }
            } else {
                content
            }
        }

        @ViewBuilder private var content: some View {
            if model.isPhotosPage {
                IOSPhotosInspector(model: model)
            } else {
                localInspector
            }
        }

        @ViewBuilder private var localInspector: some View {
            let items = model.selection?.showsLibrary == true ? model.selectedItems : []
            if items.isEmpty {
                EmptyState(
                    "No Selection", systemImage: "rectangle.dashed",
                    message: "Select videos to see what converting them would save.")
            } else {
                Form {
                    if items.count == 1 {
                        Section {
                            IOSItemSummaryHeader(item: items[0], thumbnails: model.thumbnailSource)
                        }
                    }
                    ConvertInspector(
                        sources: items.map(model.inspectorSource(for:)), preset: $model.selectionPreset,
                        advanced: $model.advanced, saveLocation: $model.saveLocation)
                    if !model.queueableItems.isEmpty, model.queueableItems.count < model.selectedItems.count {
                        Section {
                        } footer: {
                            Text("Missing files are skipped.")
                        }
                    }
                }
            }
        }
    }

    private struct IOSPhotosInspector: View {
        @Bindable var model: ConvertModel
        @State private var isChoosingFolder = false

        private var preset: Binding<Preset?> {
            Binding {
                model.photoSelectionPreset
            } set: {
                model.photoSelectionPreset = $0
            }
        }

        private var choice: Binding<PhotosSaveLocation.Choice> {
            Binding {
                model.photosSaveLocation.choice
            } set: { newValue in
                if newValue == .folder, model.photosSaveLocation.folderBookmark == nil {
                    isChoosingFolder = true
                } else {
                    model.photosSaveLocation.choice = newValue
                }
            }
        }

        var body: some View {
            let items = model.selectedPhotoItems
            if items.isEmpty {
                EmptyState(
                    "No Selection", systemImage: "rectangle.dashed",
                    message: "Select videos to see their details.")
            } else {
                Form {
                    if items.count == 1 {
                        Section { IOSItemSummaryHeader(item: items[0], thumbnails: model.thumbnailSource) }
                    } else {
                        Section {
                            Text(
                                "\(items.count) videos · \(ByteFormat.string(items.reduce(0) { $0 + $1.byteSize }))"
                            )
                            .font(.headline)
                        }
                    }
                    Section {
                        Picker("Quality", selection: preset) {
                            if preset.wrappedValue == nil { Text("Mixed").tag(Preset?.none) }
                            ForEach(Preset.allCases, id: \.self) { Text($0.displayName).tag(Preset?.some($0)) }
                        }
                    } header: {
                        Text("Quality")
                    } footer: {
                        Text("Details are checked when each video is converted.")
                    }
                    Section {
                        Picker("Save to", selection: choice) {
                            ForEach(PhotosSaveLocation.Choice.allCases) { Text($0.title).tag($0) }
                        }
                        if model.photosSaveLocation.choice == .folder, let folder = model.photosSaveLocation.folder {
                            HStack {
                                Label(folder.lastPathComponent, systemImage: "folder")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Change…") { isChoosingFolder = true }
                                    .accessibilityLabel("Change the output folder")
                            }
                        }
                    } header: {
                        Text("Save to")
                    } footer: {
                        Text(
                            model.photosSaveLocation.choice == .replace
                                ? "Each video is downloaded from iCloud when its turn comes. When the queue finishes, "
                                    + "Photos asks you to move the originals to Recently Deleted."
                                : "Each video is downloaded from iCloud when its turn comes. Your original stays in Photos."
                        )
                    }
                }
                .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try? model.photosSaveLocation.setFolder(url)
                }
            }
        }
    }

    private struct IOSItemSummaryHeader: View {
        let item: VideoItem
        let thumbnails: ThumbnailSource
        @State private var image: CGImage?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                poster
                Text(item.name)
                    .font(.headline)
                    .textSelection(.enabled)
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
                    StatusLabel(
                        "The file is missing or unavailable.", systemImage: "exclamationmark.circle", tint: .orange)
                }
            }
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
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
        }
    }
#endif
