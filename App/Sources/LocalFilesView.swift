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
                    SavingsHeader(couldFree: model.couldFreeShown, totalBytes: browser.snapshot.totalBytes) {
                        PresetPicker("Quality preset", selection: $model.preset, options: Preset.allCases) {
                            $0.displayName
                        }
                    }
                    Divider()
                    QualityFilterBar(browser: browser)
                    Divider()
                    if sections.isEmpty {
                        if browser.quality.isActive && browser.search.isEmpty {
                            NoMatchingVideos { browser.quality = QualityFilter() }
                        } else {
                            ContentUnavailableView.search(text: browser.search)
                        }
                    } else {
                        MediaGrid(sections: sections, selection: $browser.selection, onSpace: model.toggleQuickLook) {
                            item, isSelected in
                            LibraryTile(item: item, isSelected: isSelected, thumbnails: model.thumbnails)
                                .contextMenu {
                                    Button("Remove from library") { model.removeFromLibrary(clicked: item) }
                                }
                        }
                        .onDeleteCommand { model.removeSelectionFromLibrary() }
                    }
                    Divider()
                    LibraryStatusLine(model: model)
                }
            }
        }
        .navigationTitle(model.selection?.title ?? "Local files")
        .toolbar { LocalFilesToolbar(model: model) }
        .searchable(text: $browser.search, placement: .toolbar, prompt: "Search by name")
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
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

private struct LibraryStatusLine: View {
    let model: AppModel

    var body: some View {
        let snapshot = model.browser.snapshot
        let selected = model.selectedItems
        HStack(spacing: 6) {
            Text(summary(count: snapshot.items.count, bytes: snapshot.totalBytes))
            if !selected.isEmpty {
                Text(verbatim: "·")
                Text("\(selected.count) selected, \(ByteFormat.string(selected.reduce(0) { $0 + $1.byteSize }))")
            }
            Spacer()
            if model.library.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
            }
            if let error = model.library.persistenceError {
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
        "\(count == 1 ? "1 video" : "\(count) videos") · \(ByteFormat.string(bytes))"
    }
}
