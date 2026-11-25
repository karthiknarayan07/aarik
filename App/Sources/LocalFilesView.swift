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
                    if sections.isEmpty {
                        ContentUnavailableView.search(text: browser.search)
                    } else {
                        MediaGrid(sections: sections, selection: $browser.selection, onSpace: model.toggleQuickLook) {
                            item, isSelected in
                            LibraryTile(item: item, isSelected: isSelected, thumbnails: model.thumbnails)
                        }
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

private struct LocalFilesToolbar: ToolbarContent {
    let model: AppModel
    @Bindable private var browser: LibraryBrowser

    init(model: AppModel) {
        self.model = model
        self.browser = model.browser
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Group by", selection: $browser.grouping) {
                Text("Years").tag(Grouping.year)
                Text("Months").tag(Grouping.month)
                Text("All").tag(Grouping.none)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Group by")
            .help("Group videos by year or month, or show them all")
        }
        ToolbarItem {
            Picker(selection: $browser.sort) {
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
                Label("Add files…", systemImage: "plus")
            }
            .help("Add videos or folders (⌘O)")
            .accessibilityLabel("Add files")
        }
    }
}
