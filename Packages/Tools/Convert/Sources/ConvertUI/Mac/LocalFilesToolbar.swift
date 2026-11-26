import LocalLibrary
import SwiftUI

/// The Local Files toolbar: Group By in the middle, then Share, Filter and Sort, then Add Files.
struct LocalFilesToolbar: ToolbarContent {
    let model: AppModel
    @Bindable private var browser: LibraryBrowser

    init(model: AppModel) {
        self.model = model
        self.browser = model.browser
    }

    var body: some ToolbarContent {
        GridToolbar(browser: browser, shareURLs: model.shareURLs)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isImporterPresented = true
            } label: {
                Label("Add Files…", systemImage: "plus")
            }
            .help("Add videos or folders (⌘O)")
        }
    }
}

/// Group By, Share (files only), Filter and Sort, shared by both libraries' grids. Group By sits in the centre, as in
/// Photos; the rest group at the trailing edge.
struct GridToolbar: ToolbarContent {
    @Bindable var browser: LibraryBrowser
    /// The files Share sends; nil for a library whose videos aren't files, which has no Share button.
    var shareURLs: [URL]?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Group By", selection: $browser.grouping) {
                Text("Years").tag(Grouping.year)
                Text("Months").tag(Grouping.month)
                Text("All").tag(Grouping.none)
            }
            .pickerStyle(.segmented)
            .help("Group videos by year or month, or show them all")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let shareURLs {
                ShareLink(items: shareURLs) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(shareURLs.isEmpty)
                .help("Share the selected videos")
            }
            LibraryFilterMenu(browser: browser)
            Picker(selection: $browser.sort) {
                Text("Biggest First").tag(Sort.biggestFirst)
                Text("Newest First").tag(Sort.newestFirst)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            .help("Sort order")
        }
    }
}
