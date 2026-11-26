#if os(macOS)
    import AppUI
    import Convert
    import LocalLibrary
    import QuickLook
    import SwiftUI

    /// The Local Files screen: the grid under a savings header. Filters, counts and Share live in the toolbar and the
    /// subtitle. Media-type filters reuse it.
    struct LocalFilesView: View {
        @Bindable var model: ConvertModel

        var body: some View {
            @Bindable var browser = model.browser
            let sections = model.sections
            Group {
                if model.library.items.isEmpty {
                    if model.library.isScanning {
                        ProgressView("Adding videos…")
                    } else {
                        LocalFilesWelcome(error: model.library.persistenceError) { model.isImporterPresented = true }
                    }
                } else {
                    content(browser: browser, sections: sections)
                }
            }
            .navigationTitle(model.selection?.title ?? "Local Files")
            .navigationSubtitle(subtitle)
            .toolbar { LocalFilesToolbar(model: model) }
            .assistantSearchable(
                search: model.assistant.localSearch, browser: browser, sidebarBadge: model.badgeFilter,
                shrunkIDs: { model.shrunkIDs(in: model.browser) }
            )
            .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
        }

        @ViewBuilder
        private func content(browser: LibraryBrowser, sections: [MediaSection<VideoItem>]) -> some View {
            @Bindable var browser = browser
            Group {
                if sections.isEmpty {
                    // Only the empty state fills the middle; the header stays put.
                    Group {
                        if browser.quality.isActive && browser.search.isEmpty {
                            NoMatchingVideos { browser.quality = QualityFilter() }
                        } else {
                            ContentUnavailableView.search(text: browser.search)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MediaGrid(
                        sections: sections, selection: $browser.selection, name: \.name,
                        dragFile: { $0.isAvailable ? $0.fileURL : nil },
                        actions: MediaGridActions(open: model.openLocal, quickLook: model.toggleQuickLook)
                    ) { item, state in
                        LibraryTile(
                            item: item, state: state, thumbnails: model.thumbnailSource,
                            presetOverride: model.presetOverrides.shownOverride(
                                for: item.id, default: model.preset)?.displayName,
                            savingsBadge: LibraryInsight.savingsBadge(
                                for: item, preset: model.effectivePreset(for: item))
                        )
                        .contextMenu { TileMenu(model: model, item: item) }
                    }
                    .onDeleteCommand { model.removeSelectionFromLibrary() }
                }
            }
            // The header and a problem note sit in the system's bars, so the grid scrolls under them.
            .safeAreaBar(edge: .top) {
                VStack(spacing: 0) {
                    SavingsHeader(
                        couldFree: model.couldFreeShown, totalBytes: browser.snapshot.totalBytes,
                        availableCount: browser.snapshot.items.count(where: \.isAvailable)
                    ) {
                        PresetPicker("Quality Preset", selection: $model.preset, options: Preset.allCases) {
                            $0.displayName
                        }
                    }
                    StorageBarLoader(
                        items: browser.snapshot.items, preset: model.effectivePreset(for:),
                        presetKey: AnyHashable([AnyHashable(model.preset), AnyHashable(model.presetOverrides)]))
                }
            }
            .safeAreaBar(edge: .bottom) {
                if let error = model.library.persistenceError { LibraryProblemNote(text: error) }
            }
        }

        /// "218 of 1,203 videos · 29.8 GB · 3 selected, 1.2 GB"; what is still being read goes at the end.
        private var subtitle: String {
            guard !model.library.items.isEmpty else { return "" }
            let total = model.badgeFilter.map { model.library.badgeCounts[$0] ?? 0 } ?? model.library.items.count
            return model.subtitle(
                for: model.browser, total: total, selected: model.selectedItems,
                activity: model.library.isScanning ? "Scanning…" : nil)
        }
    }

    private struct LocalFilesWelcome: View {
        let error: String?
        let addFiles: () -> Void

        var body: some View {
            VStack {
                welcome
                if let error {
                    StatusLabel(error, systemImage: "exclamationmark.triangle", tint: .orange)
                        .padding()
                }
            }
        }

        private var welcome: some View {
            WelcomeState(
                "Add Videos from Finder", systemImage: "film.stack",
                lines: [
                    "Nothing changes until you add videos to the queue.",
                    "Converted copies keep the date, location and camera details.",
                    "An original goes to the Trash only after a verified copy exists, and only if you choose Replace.",
                ]
            ) {
                Button("Add Files…", action: addFiles)
                    .buttonStyle(.borderedProminent)
                    .help("Choose videos or folders, or drag them into this window")
            }
        }
    }

    /// A tile's context menu; each item acts on the selection when the tile is part of it, else on that tile.
    private struct TileMenu: View {
        let model: ConvertModel
        let item: VideoItem

        var body: some View {
            Button("Add to Queue", systemImage: "plus") { model.addToQueue(clicked: item) }
                .disabled(!model.canAddToQueue(clicked: item))
            Button("Compress…", systemImage: "rectangle.compress.vertical") { model.compressClicked(item) }
                .disabled(!model.canAddToQueue(clicked: item))
            Divider()
            Button("Open", systemImage: "arrow.up.forward.app") { model.openLocal(clicked: item) }
                .disabled(!item.isAvailable)
            Button("Show in Finder", systemImage: "folder") {
                let urls = model.contextTargets(clicked: item).filter(\.isAvailable).compactMap(\.fileURL)
                model.host.reveal(urls)
            }
            .disabled(!item.isAvailable)
            // Space does the same for the selection (the grid's own key handling).
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

    /// The quality filters hide every video in the collection.
    private struct NoMatchingVideos: View {
        let clear: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label("No Matching Videos", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No videos here match these filters.")
            } actions: {
                Button("Clear Filters", action: clear)
            }
        }
    }

    /// A read or save problem, as a quiet note above the bottom edge: the symbol carries the colour, the text doesn't.
    struct LibraryProblemNote: View {
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
