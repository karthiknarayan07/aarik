import AppCore
import Convert
import Foundation
import LocalLibrary
import Testing

@testable import Assistant

@Suite struct RedactionTests {
    private func job(_ name: String, reason: String) -> Job {
        Job(
            toolID: "x", source: URL(filePath: "/Users/jane/Movies/\(name)"), sourceBookmark: Data(), settings: Data(),
            state: .failed(reason: reason))
    }

    @MainActor
    @Test func twoAsksForOneJobShareOneModelCall() async {
        let client = FakeLanguageModelClient { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return "Because."
        }
        let explanations = OutcomeExplanations(explainer: OutcomeExplainer(client: client))
        let job = job("a.mov", reason: "Disk full")
        async let first = explanations.explain(job: job, outcome: nil)
        async let second = explanations.explain(job: job, outcome: nil)
        let answers = await [first, second]
        #expect(answers == ["Because.", "Because."])
        #expect(client.callCount == 1)
    }
}

@MainActor
@Suite struct PhotosNotYetShrunkTests {
    @Test func photosCannotTellWhatIsShrunkSoThatFilterIsDroppedWithANote() async {
        let client = FakeLanguageModelClient(returning: LibraryQuery(resolutions: ["4K"], notYetShrunk: true))
        let availability = AssistantAvailability(client: client, observesActivation: false)
        let search = AssistantSearch(availability: availability, translator: QueryTranslator(client: client))
        let browser = LibraryBrowser(collection: EmptyCollection())
        await search.submit("4K videos I have not shrunk", browser: browser, sidebarBadge: nil, shrunkIDs: nil)
        #expect(search.tokens.map(\.kind) == [.quality])
        #expect(browser.excluded.isEmpty)
        #expect(search.note.contains("not yet shrunk"))
    }
}
