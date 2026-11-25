import AppCore
import Foundation
import Testing

@testable import LocalLibrary

@MainActor
@Suite struct LibraryBrowserTests {
    private let names = ["alpha.mov", "beta.mov", "gamma.mov"]

    /// A library restored from a store, so no media has to be encoded. The files don't exist, which is fine here.
    private func makeLibrary() throws -> LocalLibrary {
        let store = BookmarkStore(directory: try Fixtures.tempDirectory())
        let inventory = MetadataInventory(items: [
            MetadataItem(key: "video.dimensions", category: .video, displayName: "Dimensions", value: "1920x1080"),
            MetadataItem(key: "video.duration", category: .video, displayName: "Duration", value: "2500"),
        ])
        try store.save(
            names.enumerated().map { index, name in
                BookmarkStore.Entry(
                    id: UUID(), path: "/nonexistent/\(name)", bookmark: nil, byteSize: Int64(100 * (index + 1)),
                    inventory: inventory)
            })
        return LocalLibrary(store: store)
    }

    private func id(_ name: String, in browser: LibraryBrowser) throws -> UUID {
        try #require(browser.library.items.first { $0.url.lastPathComponent == name }).id
    }

    @Test func selectionChangesDoNotRebuildSectionsOrSavings() throws {
        let browser = LibraryBrowser(library: try makeLibrary())
        var savingsComputes = 0
        func savings(_ key: String = "balanced") -> Int64 {
            browser.cached(key) { snapshot in
                savingsComputes += 1
                return snapshot.totalBytes / 2
            }
        }
        #expect(browser.snapshot.items.count == 3)
        #expect(savings() == 300)
        #expect(browser.snapshotBuilds == 1)
        #expect(savingsComputes == 1)

        // Clicks and arrow keys only change the selection.
        browser.selection = [try id("beta.mov", in: browser)]
        _ = browser.snapshot
        _ = browser.selectedItems
        #expect(savings() == 300)
        browser.selection = []
        _ = browser.selectedItems
        #expect(savings() == 300)
        #expect(browser.snapshotBuilds == 1)
        #expect(savingsComputes == 1)

        // A different savings key (another preset) computes once; the sections stay.
        #expect(savings("smaller") == 300)
        #expect(savingsComputes == 2)
        #expect(browser.snapshotBuilds == 1)

        // A real input change rebuilds both.
        browser.search = "alp"
        #expect(browser.snapshot.items.map(\.url.lastPathComponent) == ["alpha.mov"])
        #expect(savings() == 50)
        #expect(browser.snapshotBuilds == 2)
        #expect(savingsComputes == 3)
    }

    @Test func libraryAndQueryChangesRebuild() throws {
        let library = try makeLibrary()
        let browser = LibraryBrowser(library: library)
        _ = browser.snapshot
        browser.grouping = .none
        _ = browser.snapshot
        browser.sort = .newestFirst
        _ = browser.snapshot
        browser.filter = .k4
        #expect(browser.snapshot.items.isEmpty)
        browser.filter = nil
        library.remove([try id("gamma.mov", in: browser)])
        #expect(browser.snapshot.items.count == 2)
        #expect(browser.snapshot.totalBytes == 300)
        #expect(browser.snapshotBuilds == 5)
    }

    @Test func hiddenSelectedItemsAreNeverSelected() throws {
        let browser = LibraryBrowser(library: try makeLibrary())
        let alpha = try id("alpha.mov", in: browser)
        let beta = try id("beta.mov", in: browser)
        browser.selection = [alpha, beta]
        // Biggest first: beta (200) before alpha (100).
        #expect(browser.selectedItems.map(\.id) == [beta, alpha])

        browser.search = "alpha"
        #expect(browser.selectedItems.map(\.id) == [alpha])

        browser.search = ""
        browser.filter = .k4
        #expect(browser.selectedItems.isEmpty)
    }

    /// alpha is 4K60 (100 bytes), beta and gamma are 1080p30 (200 and 300 bytes).
    private func makeMixedLibrary() throws -> LocalLibrary {
        let store = BookmarkStore(directory: try Fixtures.tempDirectory())
        func inventory(_ dimensions: String, fps: String) -> MetadataInventory {
            MetadataInventory(items: [
                MetadataItem(key: "video.dimensions", category: .video, displayName: "Dimensions", value: dimensions),
                MetadataItem(key: "video.frameRate", category: .video, displayName: "Frame rate", value: fps),
                MetadataItem(key: "video.duration", category: .video, displayName: "Duration", value: "2500"),
            ])
        }
        let inventories = [inventory("3840x2160", fps: "59.94"), inventory("1920x1080", fps: "30")]
        try store.save(
            names.enumerated().map { index, name in
                BookmarkStore.Entry(
                    id: UUID(), path: "/nonexistent/\(name)", bookmark: nil, byteSize: Int64(100 * (index + 1)),
                    inventory: inventories[min(index, 1)])
            })
        return LocalLibrary(store: store)
    }

    @Test func qualityFilterNarrowsTotalsAndRebuildsDerivedValues() throws {
        let browser = LibraryBrowser(library: try makeMixedLibrary())
        var computes = 0
        func savings() -> Int64 {
            browser.cached("balanced") { snapshot in
                computes += 1
                return snapshot.totalBytes / 2
            }
        }
        #expect(browser.snapshot.totalBytes == 600)
        #expect(savings() == 300)
        #expect(browser.snapshot.facets.qualities.map(\.value) == [.uhd(.fps60), .fullHD(.fps30)])
        #expect(browser.snapshot.facets.qualities.map(\.count) == [1, 2])
        #expect(browser.snapshot.facets.qualities.map(\.bytes) == [100, 500])

        // The filter is part of the query: the snapshot and the cached savings follow it.
        browser.quality.qualities = [.fullHD(.fps30)]
        #expect(browser.snapshot.items.map(\.url.lastPathComponent) == ["gamma.mov", "beta.mov"])
        #expect(browser.snapshot.totalBytes == 500)
        #expect(savings() == 250)
        #expect(computes == 2)
        // Its own dimension still lists every option, so another can be added.
        #expect(browser.snapshot.facets.qualities.count == 2)

        // Setting the same value again doesn't rebuild.
        let builds = browser.snapshotBuilds
        browser.quality.qualities = [.fullHD(.fps30)]
        _ = browser.snapshot
        #expect(browser.snapshotBuilds == builds)
        #expect(savings() == 250)
        #expect(computes == 2)

        // AND with search and the media-type filter.
        browser.search = "beta"
        #expect(browser.snapshot.items.map(\.url.lastPathComponent) == ["beta.mov"])
        browser.search = ""
        browser.filter = .k4
        #expect(browser.snapshot.items.isEmpty)
        // Facets count within the media-type filter's collection.
        #expect(browser.snapshot.facets.qualities.map(\.value) == [.uhd(.fps60)])

        browser.filter = nil
        browser.quality = QualityFilter()
        #expect(browser.snapshot.totalBytes == 600)
        #expect(savings() == 300)
    }

    @Test func qualityFilterHidesSelectedItems() throws {
        let browser = LibraryBrowser(library: try makeMixedLibrary())
        let alpha = try id("alpha.mov", in: browser)
        let beta = try id("beta.mov", in: browser)
        browser.selection = [alpha, beta]
        browser.quality.qualities = [.uhd(.fps60)]
        #expect(browser.selectedItems.map(\.id) == [alpha])
    }

    @Test func badgeCountsFollowTheLibrary() throws {
        let library = try makeLibrary()
        #expect(library.badgeCounts == [.sdr: 3])
        library.remove([try #require(library.items.first).id])
        #expect(library.badgeCounts == [.sdr: 2])
    }
}
