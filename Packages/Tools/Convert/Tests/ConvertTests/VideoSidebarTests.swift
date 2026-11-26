import AppCore
import Testing

@testable import Convert
@testable import LocalLibrary

@Suite struct VideoSidebarTests {
    private func state(
        photos: Int? = nil, local: Int = 0, badges: [MediaBadge: Int] = [:], activity: ActivitySummary = .init(jobs: [])
    ) -> VideoSidebarState {
        VideoSidebarState(photosCount: photos, localCount: local, badgeCounts: badges, activity: activity)
    }

    @Test func sectionsAndItemsKeepTheirOrderAndTitles() {
        let sections = VideoSidebar.sections(state())
        #expect(sections.map(\.title) == ["Library", "Activity"])
        // Home and Ask are the shell's, so the tool lists only its own pages.
        #expect(sections[0].items.map(\.title) == ["Photos", "Local Files"])
        #expect(sections[1].items.map(\.title) == ["Queue", "Completed", "Kept as Is", "Failed"])
    }

    @Test func mediaTypesAppearOnlyWhenPresentInBadgeOrder() {
        let sections = VideoSidebar.sections(state(badges: [.sdr: 2, .k4: 5]))
        #expect(sections.map(\.title) == ["Library", "Media Types", "Activity"])
        #expect(sections[1].items.map(\.title) == ["4K", "SDR"])
        #expect(sections[1].items.map(\.count) == [5, 2])
        #expect(sections[1].items.map(\.destination) == [.mediaType(.k4), .mediaType(.sdr)])
    }

    @Test func countsComeFromTheStateAndPhotosStaysUnbadgedUntilLoaded() {
        let unloaded = VideoSidebar.sections(state(local: 7))[0].items
        #expect(unloaded.map(\.count) == [nil, 7])
        let loaded = VideoSidebar.sections(state(photos: 12, local: 7))[0].items
        #expect(loaded.map(\.count) == [12, 7])
    }

    @Test func pagesShowTheLibraryOnlyForLocalFilesAndMediaTypes() {
        #expect(VideoPage.localFiles.showsLibrary)
        #expect(VideoPage.mediaType(.hdr).showsLibrary)
        #expect(!VideoPage.photosVideos.showsLibrary)
        #expect(!VideoPage.queue.showsLibrary)
    }

    @Test func theToolNeverListsHomeOrAskAndTheShellAddsThem() {
        let tool = VideoSidebar.sections(state())
        let destinations = tool.flatMap(\.items).compactMap(\.destination)
        #expect(!destinations.contains(.overview))
        #expect(!destinations.contains(.ask))

        let withAsk = MacSidebarModel(showsAsk: true, tool: tool)
        #expect(withAsk.selectablePages.prefix(2) == [.home, .ask])
        #expect(withAsk.selectablePages.dropFirst(2).first == .page(.photosVideos))
        let withoutAsk = MacSidebarModel(showsAsk: false, tool: tool)
        #expect(!withoutAsk.selectablePages.contains(.ask))
        #expect(!withoutAsk.accepts(.ask))
        #expect(withoutAsk.accepts(.home))
        #expect(withoutAsk.accepts(.page(.queue)))
        #expect(!withoutAsk.accepts(.page(.overview)))
    }

    @Test func pagesComeBackFromTheirStoredKeyAndFiltersAreNotStored() {
        for page in [VideoPage.overview, .photosVideos, .localFiles, .queue, .completed, .keptAsIs, .failed, .ask] {
            #expect(page.persistenceKey.flatMap(VideoPage.init(persistenceKey:)) == page)
        }
        #expect(VideoPage.mediaType(.k4).persistenceKey == nil)
        #expect(VideoPage(persistenceKey: "nonsense") == nil)
    }
}
