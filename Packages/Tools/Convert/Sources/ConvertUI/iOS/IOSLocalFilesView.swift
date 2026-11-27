#if os(iOS)
    import AppCore
    import AppUI
    import Convert
    import LocalLibrary
    import QuickLook
    import SwiftUI

    /// iOS Local Files browser: imports videos or folders via `.fileImporter`, shows estimated savings, and lets
    /// users pick videos to queue (outputs saved to Documents or a chosen folder; Replace disabled).
    struct IOSLocalFilesView: View {
        @Bindable var model: ConvertModel
        @State private var opened: UUID?
        @State private var isSelecting = false
        @Namespace private var zoom

        var body: some View {
            @Bindable var browser = model.browser
            let sections = model.sections
            Group {
                if model.library.items.isEmpty {
                    if model.library.isScanning {
                        ProgressView("Adding files…")
                    } else {
                        IOSLocalFilesWelcome(error: model.library.persistenceError) {
                            model.isImporterPresented = true
                        }
                    }
                } else {
                    content(browser: browser, sections: sections)
                }
            }
            .navigationTitle(IOSPage.files.title)
            .navigationSubtitle(subtitle)
            .toolbar {
                IOSGridToolbar(browser: browser, shareURLs: model.shareURLs, isSelecting: $isSelecting)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isImporterPresented = true
                    } label: {
                        Label("Add Files…", systemImage: "plus.circle")
                    }
                }
            }
            .assistantSearchable(
                search: model.assistant.localSearch, browser: browser, sidebarBadge: model.badgeFilter,
                shrunkIDs: { model.shrunkIDs(in: model.browser) }
            )
            .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
            .sensoryFeedback(.selection, trigger: browser.selection)
            .safeAreaInset(edge: .bottom) {
                IOSSelectionBar(
                    model: model, count: model.selectedItems.count, isSelecting: $isSelecting,
                    clear: { browser.selection = [] })
            }
            .animation(.smooth, value: isSelecting)
            .onChange(of: isSelecting) { _, newValue in
                model.isSelecting = newValue
            }
            .onChange(of: opened) { _, newValue in
                if newValue == nil, !isSelecting { browser.selection = [] }
            }
            .onDisappear { model.isSelecting = false }
            .navigationDestination(item: $opened) { id in
                IOSVideoDetailView(model: model, id: id)
                    .navigationTransition(.zoom(sourceID: id, in: zoom))
            }
        }

        @ViewBuilder
        private func content(browser: LibraryBrowser, sections: [MediaSection<VideoItem>]) -> some View {
            @Bindable var browser = browser
            Group {
                if sections.isEmpty {
                    Group {
                        if browser.quality.isActive && browser.search.isEmpty {
                            ContentUnavailableView {
                                Label("No Matching Videos", systemImage: "line.3.horizontal.decrease.circle")
                            } description: {
                                Text("No videos here match these filters.")
                            } actions: {
                                Button("Clear Filters") { browser.quality = QualityFilter() }
                            }
                        } else {
                            ContentUnavailableView.search(text: browser.search)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MediaGrid(
                        sections: sections, selection: $browser.selection, name: \.name,
                        actions: MediaGridActions(open: { opened = $0.first }, quickLook: model.toggleQuickLook),
                        opensOnTap: !isSelecting
                    ) {
                        VStack(spacing: 0) {
                            MediaKindPicker(selection: $browser.mediaFilter)
                                .padding(.horizontal)
                                .padding(.top, 8)
                            SavingsHeader(
                                couldFree: model.couldFreeShown, totalBytes: browser.snapshot.totalBytes,
                                availableCount: browser.snapshot.items.count(where: \.isAvailable)
                            ) {
                                Menu {
                                    Picker("Resolution", selection: $model.advanced.resolution) {
                                        ForEach(AdvancedOptions.Resolution.allCases, id: \.self) {
                                            Text($0.title).tag($0)
                                        }
                                    }
                                } label: {
                                    Label(model.advanced.resolution.title, systemImage: "slider.horizontal.3")
                                }
                            }
                        }
                    } tile: { item, state in
                        LibraryTile(
                            item: item, state: state, thumbnails: model.thumbnailSource,
                            presetOverride: model.presetOverrides.shownOverride(
                                for: item.id, default: model.preset)?.displayName
                        ).equatable()
                            .matchedTransitionSource(id: item.id, in: zoom)
                            .contextMenu {
                                IOSTileMenu(model: model, item: item)
                            } preview: {
                                LibraryTile(item: item, state: MediaTileState(), thumbnails: model.thumbnailSource)
                                    .frame(width: 280, height: 190)
                            }
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if let error = model.library.persistenceError { IOSProblemNote(text: error) }
            }
        }

        private var subtitle: String {
            guard !model.library.items.isEmpty else { return "" }
            let badge = model.badgeFilter
            let total = model.library.items.count { item in badge.map(item.badges.contains) ?? true }
            return model.subtitle(
                for: model.browser, total: total, selected: model.selectedItems,
                activity: model.library.isScanning ? "Scanning…" : nil)
        }
    }

    /// Adaptive toolbar for library grids: inline controls on regular width (iPad), compact menu on iPhone/folded Duo.
    struct IOSGridToolbar: ToolbarContent {
        @Bindable var browser: LibraryBrowser
        var shareURLs: [URL]?
        @Binding var isSelecting: Bool
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        var body: some ToolbarContent {
            ToolbarItem(placement: .primaryAction) {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { browser.selection = [] }
                }
                .accessibilityIdentifier("selectToggle")
            }
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let shareURLs, !shareURLs.isEmpty {
                            ShareLink(items: shareURLs) {
                                Label("Share…", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                        }
                        Picker("Group By", selection: $browser.grouping) {
                            Text("Years").tag(Grouping.year)
                            Text("Months").tag(Grouping.month)
                            Text("All").tag(Grouping.none)
                        }
                        Picker("Sort", selection: $browser.sort) {
                            Text("Biggest First").tag(Sort.biggestFirst)
                            Text("Newest First").tag(Sort.newestFirst)
                        }
                        Divider()
                        Button("Select All", systemImage: "checkmark.circle") {
                            browser.selection = Set(browser.snapshot.items.map(\.id))
                        }
                        if !browser.selection.isEmpty {
                            Button("Deselect All", systemImage: "xmark.circle") {
                                browser.selection = []
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    LibraryFilterMenu(browser: browser)
                }
            } else {
                GridToolbar(browser: browser, shareURLs: shareURLs)
            }
        }
    }

    private struct IOSLocalFilesWelcome: View {
        let error: String?
        let addFiles: () -> Void

        var body: some View {
            VStack {
                WelcomeState(
                    "Add Media from Files", systemImage: "photo.on.rectangle.angled",
                    lines: [
                        "Nothing changes until you add items to the queue.",
                        "Converted copies keep the date, location and camera details.",
                        "Converted Files items are saved to \(DeviceCopy.filesAppLocation).",
                    ]
                ) {
                    Button("Add Files…", action: addFiles)
                        .buttonStyle(.borderedProminent)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .padding()
                }
            }
        }
    }

    private struct IOSTileMenu: View {
        let model: ConvertModel
        let item: VideoItem

        var body: some View {
            Button("Add to Queue", systemImage: "plus") { model.addToQueue(clicked: item) }
                .disabled(!model.canAddToQueue(clicked: item))
            Divider()
            Button("Quick Look", systemImage: "eye") { model.quickLook(clicked: item) }
                .disabled(!item.isAvailable)
            ShareLink(items: model.shareURLs(clicked: item)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .disabled(!item.isAvailable)
            Divider()
            Button("Remove from Library", systemImage: "minus.circle") { model.removeFromLibrary(clicked: item) }
        }
    }

    struct IOSProblemNote: View {
        let text: String

        var body: some View {
            Label {
                Text(text).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
#endif
