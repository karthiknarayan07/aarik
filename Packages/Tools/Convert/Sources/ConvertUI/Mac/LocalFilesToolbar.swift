import Convert
import LocalLibrary
import SwiftUI

/// The Local Files toolbar: Group By, Share, Filter and Sort, then Add Files.
struct LocalFilesToolbar: ToolbarContent {
    let model: ConvertModel
    @Bindable private var browser: LibraryBrowser

    init(model: ConvertModel) {
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

/// Group By, Share (files only), Filter and Sort, shared by both libraries' grids, grouped at the trailing edge.
struct GridToolbar: ToolbarContent {
    @Bindable var browser: LibraryBrowser
    /// The files Share sends; nil for a library whose videos aren't files, which has no Share button.
    var shareURLs: [URL]?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // A menu, like Finder's Group By, instead of a segmented bar in the middle of the title bar.
            Picker(selection: $browser.grouping) {
                Text("Years").tag(Grouping.year)
                Text("Months").tag(Grouping.month)
                Text("All").tag(Grouping.none)
            } label: {
                Label("Group By", systemImage: "rectangle.3.group")
            }
            .pickerStyle(.menu)
            .help("Group videos by year or month, or show them all")
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
