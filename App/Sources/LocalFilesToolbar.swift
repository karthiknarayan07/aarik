import LocalLibrary
import SwiftUI

/// Group By, Sort and Add Files for the library grid.
struct LocalFilesToolbar: ToolbarContent {
    let model: AppModel
    @Bindable private var browser: LibraryBrowser

    init(model: AppModel) {
        self.model = model
        self.browser = model.browser
    }

    var body: some ToolbarContent {
        GridToolbar(browser: browser)
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

/// Group by and sort, shared by both libraries' grids.
struct GridToolbar: ToolbarContent {
    @Bindable var browser: LibraryBrowser

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Group By", selection: $browser.grouping) {
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
                Text("Biggest First").tag(Sort.biggestFirst)
                Text("Newest First").tag(Sort.newestFirst)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Sort order")
            .help("Sort order")
        }
    }
}
