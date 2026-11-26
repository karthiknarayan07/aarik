import CoreGraphics
import Foundation
import Observation
import Testing

@testable import Convert
@testable import Assistant
@testable import LocalLibrary

@MainActor
@Observable
private final class Collection: MediaCollection {
    var items: [LibraryItem] = [] { didSet { revision += 1 } }
    private(set) var revision = 0
    var isScanning = false
}

@MainActor
@Suite struct AssistantSearchTests {
    private static let today = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String, height: CGFloat = 2160) -> LibraryItem {
        LibraryItem(
            id: UUID(), source: .photos(name), name: name, byteSize: 800_000_000, duration: 5,
            pixelSize: CGSize(width: height * 16 / 9, height: height), frameRate: 30, captureDate: nil,
            badges: [], isAvailable: true, inventory: .init())
    }

    private struct Rig {
        let client: FakeLanguageModelClient
        let availability: AssistantAvailability
        let search: AssistantSearch
        let browser: LibraryBrowser
        let collection: Collection
    }

    private func rig(
        available: Bool = true, answer: LibraryQuery = LibraryQuery(resolutions: ["4K"])
    ) -> Rig {
        let client = FakeLanguageModelClient(isAvailable: available, handler: { _, _ in answer })
        let availability = AssistantAvailability(client: client, observesActivation: false)
        let search = AssistantSearch(availability: availability, translator: QueryTranslator(client: client))
        let collection = Collection()
        collection.items = [item("a.mov"), item("b.mov", height: 1080)]
        return Rig(
            client: client, availability: availability, search: search,
            browser: LibraryBrowser(collection: collection), collection: collection)
    }

    // MARK: Hidden when unavailable

    @Test func everythingIsHiddenWhenTheModelIsUnavailable() async {
        let rig = rig(available: false)
        #expect(!rig.availability.isAvailable)
        #expect(!rig.search.isVisible)
        #expect(rig.search.tokens.isEmpty)
        #expect(rig.search.note.isEmpty)
        await rig.search.submit("show me my 4K videos", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.client.callCount == 0)
        #expect(rig.browser.search.isEmpty)
        #expect(!rig.browser.quality.isActive)
    }

    @Test func focusingTheSearchFieldReadsAvailabilityAgainWithoutAnActivation() {
        let rig = rig(available: false)
        #expect(!rig.search.isVisible)

        // Apple Intelligence was turned on in System Settings; no app activation has happened.
        rig.client.isAvailable = true
        #expect(!rig.search.isVisible)
        rig.search.searchFieldGainedFocus()
        #expect(rig.search.isVisible)

        // And off again: the sparkle goes at the next focus, and nothing is left behind.
        rig.client.isAvailable = false
        rig.search.searchFieldGainedFocus()
        #expect(!rig.search.isVisible)
        #expect(rig.search.tokens.isEmpty)
    }

    @Test func turningTheModelOnShowsTheControlsAndOffRemovesWhatItApplied() async {
        let rig = rig(available: false)
        rig.client.isAvailable = true
        rig.availability.refresh()
        #expect(rig.search.isVisible)
        await rig.search.submit("show me my 4K videos", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.browser.snapshot.items.count == 1)
        #expect(!rig.search.tokens.isEmpty)

        rig.client.isAvailable = false
        rig.availability.refresh()
        rig.search.availabilityChanged(browser: rig.browser, sidebarBadge: nil)
        #expect(!rig.search.isVisible)
        #expect(rig.search.tokens.isEmpty)
        #expect(rig.search.note.isEmpty)
        #expect(!rig.browser.quality.isActive)
        #expect(rig.browser.snapshot.items.count == 2)
    }

    // MARK: Applying

    @Test func aSentenceBecomesTokensAnEchoAndAFilteredGrid() async {
        let rig = rig()
        await rig.search.submit("show me my 4K videos", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.search.tokens.map(\.title) == ["4K"])
        #expect(rig.search.note == "Showing 4K videos")
        #expect(rig.browser.snapshot.items.map(\.name) == ["a.mov"])
        #expect(rig.browser.search.isEmpty)
    }

    @Test func removingATokenRemovesThatFilter() async {
        let rig = rig(answer: LibraryQuery(resolutions: ["4K"], minimumSizeMegabytes: 500))
        await rig.search.submit("4K over 500 MB", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.search.tokens.map(\.kind) == [.quality, .size])
        rig.search.tokensChanged(
            to: rig.search.tokens.filter { $0.kind != .quality }, browser: rig.browser, sidebarBadge: nil)
        #expect(rig.search.tokens.map(\.kind) == [.size])
        #expect(rig.browser.quality.qualities.isEmpty)
        #expect(rig.browser.quality.minimumSize == .over500MB)
        #expect(rig.search.note == "Showing videos over 500 MB")
        rig.search.tokensChanged(to: [], browser: rig.browser, sidebarBadge: nil)
        #expect(!rig.browser.quality.isActive)
        #expect(rig.search.note.isEmpty)
    }

    @Test func notYetShrunkHidesTheItemsGivenAsShrunk() async {
        let rig = rig(answer: LibraryQuery(notYetShrunk: true))
        let shrunk = rig.collection.items[0].id
        await rig.search.submit("what haven't I shrunk", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [shrunk])
        #expect(rig.browser.snapshot.items.map(\.name) == ["b.mov"])
    }

    @Test func nameTextGoesToThePlainSearchField() async {
        let rig = rig(answer: LibraryQuery(nameText: "a.mov"))
        await rig.search.submit("the a one", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.browser.search == "a.mov")
        #expect(rig.search.tokens.isEmpty)
    }

    @Test func theSidebarsMediaTypeSurvivesAndIsRestored() async {
        let rig = rig()
        rig.browser.filter = .hdr
        await rig.search.submit("4K", browser: rig.browser, sidebarBadge: .hdr, shrunkIDs: [])
        #expect(rig.browser.filter == .hdr)
        rig.search.reset(browser: rig.browser, sidebarBadge: .hdr)
        #expect(rig.browser.filter == .hdr)
    }

    // MARK: Falling back to plain search

    @Test func aFailedRequestDoesAPlainSearchWithoutAnyAssistantUI() async {
        let client = FakeLanguageModelClient { _, _ in throw AssistantError.guardrail }
        let availability = AssistantAvailability(client: client, observesActivation: false)
        let search = AssistantSearch(availability: availability, translator: QueryTranslator(client: client))
        let browser = LibraryBrowser(collection: Collection())
        await search.submit("something the model refuses", browser: browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(browser.search == "something the model refuses")
        #expect(search.tokens.isEmpty)
        #expect(search.note.isEmpty)
        #expect(!search.isWorking)
    }

    @Test func nonsenseTheModelCannotMapIsAPlainSearch() async {
        let rig = rig(answer: LibraryQuery())
        await rig.search.submit("asdf qwer zxcv", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.browser.search == "asdf qwer zxcv")
        #expect(rig.search.tokens.isEmpty)
    }

    @Test func onlyUnknownValuesChangeNothingButExplainWhy() async {
        let rig = rig(answer: LibraryQuery(resolutions: ["8K"]))
        await rig.search.submit("show me 8K videos", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.browser.search.isEmpty)
        #expect(rig.browser.snapshot.items.count == 2)
        #expect(rig.search.note.contains("8K"))
    }

    @Test func aSecondQueryReplacesTheFirst() async {
        let rig = rig(answer: LibraryQuery(resolutions: ["4K"], minimumSizeMegabytes: 500))
        await rig.search.submit("one", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        await rig.search.submit("two words here", browser: rig.browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(rig.search.tokens.count == 2)
        #expect(rig.client.callCount == 2)
    }

    // MARK: Sentences

    @Test func onlySentencesGoToTheModel() {
        #expect(!AssistantSearch.looksLikeSentence("beach"))
        #expect(!AssistantSearch.looksLikeSentence("IMG 1234"))
        #expect(!AssistantSearch.looksLikeSentence("   "))
        #expect(AssistantSearch.looksLikeSentence("4K videos over 500 MB"))
        #expect(AssistantSearch.looksLikeSentence("videos from last summer"))
    }
}
