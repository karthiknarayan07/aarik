import AppUI
import DownscaleVideo
import LocalLibrary
import QuickLook
import SwiftUI

/// The Local Files screen: savings header, the grid, and a status line. Media-type filters reuse it.
struct LocalFilesView: View {
    @Bindable var model: AppModel

    var body: some View {
        let sections = model.sections
        let shown = sections.flatMap(\.items)
        Group {
            if model.library.items.isEmpty {
                if model.library.isScanning {
                    ProgressView("Adding videos…")
                } else {
                    LocalFilesWelcome { model.isImporterPresented = true }
                }
            } else {
                VStack(spacing: 0) {
                    SavingsHeader(
                        couldFree: model.couldFreeBytes(for: shown),
                        totalBytes: shown.reduce(0) { $0 + $1.byteSize }
                    ) {
                        PresetPicker("Quality preset", selection: $model.preset, options: Preset.allCases) {
                            $0.displayName
                        }
                    }
                    Divider()
                    if sections.isEmpty {
                        ContentUnavailableView.search(text: model.searchText)
                    } else {
                        MediaGrid(
                            sections: sections, selection: $model.selectedItemIDs, onSpace: model.toggleQuickLook
                        ) { item, isSelected in
                            LibraryTile(item: item, isSelected: isSelected, thumbnails: model.thumbnails)
                        }
                    }
                    Divider()
                    LibraryStatusLine(model: model, shown: shown)
                }
            }
        }
        .navigationTitle(model.selection?.title ?? "Local files")
        .toolbar { LocalFilesToolbar(model: model) }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search by name")
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
        .onChange(of: model.badgeFilter) {
            let visible = Set(model.shownItems.map(\.id))
            model.selectedItemIDs.formIntersection(visible)
        }
    }
}

private struct LocalFilesWelcome: View {
    let addFiles: () -> Void

    var body: some View {
        WelcomeState(
            "Add videos from Finder", systemImage: "film.stack",
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

private struct LibraryStatusLine: View {
    let model: AppModel
    let shown: [VideoItem]

    var body: some View {
        let selected = model.selectedItems
        HStack(spacing: 6) {
            Text(summary(count: shown.count, bytes: shown.reduce(0) { $0 + $1.byteSize }))
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

private struct LocalFilesToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Group by", selection: $model.grouping) {
                Text("Years").tag(Grouping.year)
                Text("Months").tag(Grouping.month)
                Text("All").tag(Grouping.none)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Group by")
            .help("Group videos by year or month, or show them all")
        }
        ToolbarItem {
            Picker(selection: $model.sort) {
                Text("Biggest first").tag(Sort.biggestFirst)
                Text("Newest first").tag(Sort.newestFirst)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Sort order")
            .help("Sort order")
        }
        ToolbarItem {
            Button {
                model.isImporterPresented = true
            } label: {
                Label("Add Files…", systemImage: "plus")
            }
            .help("Add videos or folders (⌘O)")
            .accessibilityLabel("Add files")
        }
    }
}
