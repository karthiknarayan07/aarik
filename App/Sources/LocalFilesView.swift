import AppKit
import AppUI
import DownscaleVideo
import LocalLibrary
import QuickLook
import SwiftUI

/// The Local Files screen: savings header, the grid, and a status line. Media-type filters reuse it.
struct LocalFilesView: View {
    @Bindable var model: AppModel

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
                VStack(spacing: 0) {
                    SavingsHeader(
                        couldFree: model.couldFreeShown, totalBytes: browser.snapshot.totalBytes,
                        availableCount: browser.snapshot.items.count(where: \.isAvailable)
                    ) {
                        PresetPicker("Quality preset", selection: $model.preset, options: Preset.allCases) {
                            $0.displayName
                        }
                    }
                    Divider()
                    QualityFilterBar(browser: browser)
                    Divider()
                    if sections.isEmpty {
                        // Only the empty state fills the middle; the header, filters and status line stay put.
                        Group {
                            if browser.quality.isActive && browser.search.isEmpty {
                                NoMatchingVideos { browser.quality = QualityFilter() }
                            } else {
                                ContentUnavailableView.search(text: browser.search)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        MediaGrid(sections: sections, selection: $browser.selection, onSpace: model.toggleQuickLook) {
                            item, isSelected in
                            LibraryTile(
                                item: item, isSelected: isSelected, thumbnails: model.thumbnailSource,
                                presetOverride: model.presetOverrides.shownOverride(
                                    for: item.id, default: model.preset)?.displayName
                            )
                            .contextMenu { TileMenu(model: model, item: item) }
                        }
                        .onDeleteCommand { model.removeSelectionFromLibrary() }
                    }
                    Divider()
                    LibraryStatusLine(
                        browser: model.browser, isScanning: model.library.isScanning, scanningLabel: "Scanning…",
                        error: model.library.persistenceError)
                }
            }
        }
        .navigationTitle(model.selection?.title ?? "Local files")
        .navigationSubtitle(filteredSummary)
        .toolbar { LocalFilesToolbar(model: model) }
        .assistantSearchable(
            search: model.assistant.localSearch, browser: browser, sidebarBadge: model.badgeFilter,
            shrunkIDs: { model.shrunkIDs(in: model.browser) }
        )
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
    }

    /// What the quality filters leave, for example "218 videos · 29.8 GB"; empty when none is set.
    private var filteredSummary: String {
        let browser = model.browser
        guard browser.quality.isActive, !model.library.items.isEmpty else { return "" }
        let snapshot = browser.snapshot
        return VideoCount.summary(count: snapshot.items.count, bytes: snapshot.totalBytes)
    }
}

private struct LocalFilesWelcome: View {
    let error: String?
    let addFiles: () -> Void

    var body: some View {
        VStack {
            welcome
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding()
            }
        }
    }

    private var welcome: some View {
        WelcomeState(
            "Add videos from Finder", systemImage: "film.stack",
            lines: [
                "Nothing changes until you add videos to the queue.",
                "Converted copies keep the date, location and camera details.",
                "An original goes to the Trash only after a verified copy exists, and only if you choose Replace.",
            ]
        ) {
            Button("Add files…", action: addFiles)
                .buttonStyle(.borderedProminent)
                .help("Choose videos or folders, or drag them into this window")
        }
    }
}

/// A tile's context menu; each item acts on the selection when the tile is part of it, else on that tile.
private struct TileMenu: View {
    let model: AppModel
    let item: VideoItem

    var body: some View {
        Button("Add to queue", systemImage: "plus") { model.addToQueue(clicked: item) }
            .disabled(!model.canAddToQueue(clicked: item))
        Divider()
        Button("Show in Finder", systemImage: "folder") {
            let urls = model.contextTargets(clicked: item).filter(\.isAvailable).compactMap(\.fileURL)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        .disabled(!item.isAvailable)
        // Space does the same for the selection (the grid's own key handling).
        Button("Quick Look", systemImage: "eye") { model.quickLook(clicked: item) }
            .disabled(!item.isAvailable)
        Divider()
        Button("Remove from library", systemImage: "minus.circle") { model.removeFromLibrary(clicked: item) }
    }
}

/// The quality filters hide every video in the collection.
private struct NoMatchingVideos: View {
    let clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No matching videos", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No videos here match these filters.")
        } actions: {
            Button("Clear filters", action: clear)
        }
    }
}

/// Count and size of what's shown, the selection, and a progress or error note; shared by both libraries.
struct LibraryStatusLine: View {
    let browser: LibraryBrowser
    let isScanning: Bool
    let scanningLabel: String
    let error: String?

    var body: some View {
        let snapshot = browser.snapshot
        let selected = browser.selectedItems
        HStack(spacing: 6) {
            Text(summary(count: snapshot.items.count, bytes: snapshot.totalBytes))
            if !selected.isEmpty {
                Text(verbatim: "·")
                Text("\(selected.count) selected, \(ByteFormat.string(selected.reduce(0) { $0 + $1.byteSize }))")
            }
            Spacer()
            if isScanning {
                ProgressView().controlSize(.small)
                Text(scanningLabel)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func summary(count: Int, bytes: Int64) -> String {
        VideoCount.summary(count: count, bytes: bytes)
    }
}
