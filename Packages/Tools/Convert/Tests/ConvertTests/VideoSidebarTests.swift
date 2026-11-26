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
        #expect(sections.map(\.title) == ["Library", "Tools", "Activity"])
        #expect(sections[0].items.map(\.title) == ["Overview", "Videos", "Local Files"])
        #expect(sections[1].items.map(\.title) == ["Downscale Video", "Convert Image", "PDF Tools"])
        #expect(sections[2].items.map(\.title) == ["Queue", "Completed", "Kept as Is", "Failed"])
    }

    @Test func mediaTypesAppearOnlyWhenPresentInBadgeOrder() {
        let sections = VideoSidebar.sections(state(badges: [.sdr: 2, .k4: 5]))
        #expect(sections.map(\.title) == ["Library", "Media Types", "Tools", "Activity"])
        #expect(sections[1].items.map(\.title) == ["4K", "SDR"])
        #expect(sections[1].items.map(\.count) == [5, 2])
        #expect(sections[1].items.map(\.destination) == [.mediaType(.k4), .mediaType(.sdr)])
    }

    @Test func countsComeFromTheStateAndPhotosStaysUnbadgedUntilLoaded() {
        let unloaded = VideoSidebar.sections(state(local: 7))[0].items
        #expect(unloaded.map(\.count) == [nil, nil, 7])
        let loaded = VideoSidebar.sections(state(photos: 12, local: 7))[0].items
        #expect(loaded.map(\.count) == [nil, 12, 7])
    }

    @Test func comingSoonToolsAreNotSelectable() {
        let tools = VideoSidebar.sections(state())[1].items
        #expect(tools.map(\.availability) == [.available, .comingSoon, .comingSoon])
        #expect(tools.map(\.destination) == [.tool(ConvertTool.descriptor.id), nil, nil])
    }

    @Test func pagesShowTheLibraryOnlyForLocalFilesAndMediaTypes() {
        #expect(VideoPage.localFiles.showsLibrary)
        #expect(VideoPage.mediaType(.hdr).showsLibrary)
        #expect(!VideoPage.photosVideos.showsLibrary)
        #expect(!VideoPage.queue.showsLibrary)
    }
}
