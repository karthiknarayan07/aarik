import AarikCore
import Foundation
import LocalLibrary
import Testing

@testable import Assistant

@Suite struct CancellationTests {
    private static let today = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theTimeoutCancelsACooperativeRequestAndReturnsInTime() async {
        let probe = CancellationProbe()
        let client = FakeLanguageModelClient { _, _ in try await probe.waitUntilCancelled() }
        let translator = QueryTranslator(client: client, timeout: .milliseconds(150))
        let started = ContinuousClock.now
        let result = await translator.translate("4K videos", today: Self.today)
        let elapsed = ContinuousClock.now - started
        #expect(result.failure == .timedOut)
        #expect(elapsed < .seconds(2))
        #expect(await probe.waitForCancellation())
    }

    @Test func cancellingTheCallerCancelsTheRequestAndReportsCancelled() async {
        let probe = CancellationProbe()
        let client = FakeLanguageModelClient { _, _ in try await probe.waitUntilCancelled() }
        let translator = QueryTranslator(client: client, timeout: .seconds(30))
        let task = Task { await translator.translate("4K videos", today: Self.today) }
        while !probe.started { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let result = await task.value
        #expect(result.failure == .cancelled)
        #expect(await probe.waitForCancellation())
    }

    @Test func theExplainerCancelsToo() async {
        let probe = CancellationProbe()
        let client = FakeLanguageModelClient { _, _ in try await probe.waitUntilCancelled() }
        let explainer = OutcomeExplainer(client: client, timeout: .milliseconds(150))
        let job = Job(
            toolID: "x", source: URL(filePath: "/a/b.mov"), sourceBookmark: Data(), settings: Data(),
            state: .failed(reason: "Disk full"))
        let text = await explainer.explain(job: job, outcome: nil, report: nil)
        #expect(text == "Disk full")
        #expect(await probe.waitForCancellation())
    }

    @MainActor
    @Test func aCancelledTranslationLeavesTheSearchAsItWas() async {
        let probe = CancellationProbe()
        let client = FakeLanguageModelClient { _, _ in try await probe.waitUntilCancelled() }
        let availability = AssistantAvailability(client: client, observesActivation: false)
        let search = AssistantSearch(
            availability: availability, translator: QueryTranslator(client: client, timeout: .seconds(30)))
        let browser = LibraryBrowser(collection: EmptyCollection())
        browser.search = "what I typed"
        browser.quality = QualityFilter(minimumSize: .over1GB)
        let task = Task {
            await search.submit(
                "what I typed", browser: browser, sidebarBadge: nil, shrunkIDs: [], today: Self.today)
        }
        while !probe.started { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await task.value
        #expect(browser.search == "what I typed")
        #expect(browser.quality.minimumSize == .over1GB)
        #expect(search.tokens.isEmpty)
        #expect(search.note.isEmpty)
        #expect(!search.isWorking)
    }

    @MainActor
    @Test func aTimeoutStillFallsBackToPlainSearch() async {
        let client = FakeLanguageModelClient { _, _ in try await hangForever() }
        let availability = AssistantAvailability(client: client, observesActivation: false)
        let search = AssistantSearch(
            availability: availability, translator: QueryTranslator(client: client, timeout: .milliseconds(100)))
        let browser = LibraryBrowser(collection: EmptyCollection())
        await search.submit("4K videos please", browser: browser, sidebarBadge: nil, shrunkIDs: [])
        #expect(browser.search == "4K videos please")
    }

    // MARK: Real model

    @Test(.enabled(if: SystemLanguageModelClient().isAvailable), .timeLimit(.minutes(1)))
    func realModelStopsPromptlyWhenCancelled() async {
        let client = SystemLanguageModelClient()
        let task = Task {
            try await client.respond(
                to: "Write a very long, detailed story about a lighthouse keeper, at least two thousand words.",
                instructions: "You are a storyteller.")
        }
        try? await Task.sleep(for: .milliseconds(700))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let elapsed = ContinuousClock.now - cancelledAt
        print("REALMODEL cancel result:", String(describing: result).prefix(80), "after", elapsed)
        #expect(elapsed < .seconds(5))
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        }
    }
}

@MainActor
final class EmptyCollection: MediaCollection {
    let items: [LibraryItem] = []
    let revision = 0
    let isScanning = false
}
