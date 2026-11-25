import AppCore
import AppUI
import CoreGraphics
import DownscaleVideo
import Foundation
import LocalLibrary
import Observation
import Synchronization
import Testing

@testable import Assistant

/// A synthetic set of groups, as the analyzer would rank them: the biggest saving first.
private func makeBuckets(_ count: Int) -> [SavingsBucket] {
    let years = [2025, 2024, 2023, 2022, 2021, 2020]
    let qualities: [QualityBucket] = [.uhd(.fps30), .uhd(.fps60), .fullHD(.fps30), .uhd(.fps24)]
    return (0..<count).map { index in
        let library: OverviewSummary.Library = index % 3 == 2 ? .localFiles : .photos
        return SavingsBucket(
            id: "B\(index + 1)", quality: qualities[index % qualities.count], year: years[index % years.count],
            library: library, excludesShrunk: library == .localFiles, count: 400 - index * 20,
            bytes: Int64(120 - index * 5) * 1_000_000_000, couldFree: Int64(70 - index * 3) * 1_000_000_000,
            itemIDs: [UUID(), UUID()])
    }
}

private func draft(_ id: String, title: String = "Shrink these first", why: String = "They take a lot of room.")
    -> SmartPickDraft
{
    SmartPickDraft(title: title, why: why, bucketID: id)
}

@Suite struct SmartPickerTests {
    private let buckets = makeBuckets(5)

    private func picker(returning answer: SmartPicks, timeout: Duration = .seconds(5)) -> (
        SmartPicker, FakeLanguageModelClient
    ) {
        let client = FakeLanguageModelClient(returning: answer)
        return (SmartPicker(client: client, timeout: timeout), client)
    }

    // MARK: Prompt

    @Test func theLargeLibraryPromptHoldsTheTopTwelveGroupsOnOneLineEach() async {
        let (picker, client) = picker(returning: SmartPicks(picks: [draft("B1")]))
        let outcome = await picker.picks(from: makeBuckets(40))
        guard case .picks = outcome else {
            Issue.record("expected picks")
            return
        }
        let prompt = client.prompts[0]
        let lines = prompt.split(separator: "\n").dropFirst()
        #expect(lines.count == SavingsAnalyzer.promptLimit)
        #expect(SavingsAnalyzer.promptLimit <= 12)
        #expect(lines.first?.hasPrefix("B1: ") == true)
        #expect(lines.last?.hasPrefix("B12: ") == true)
        #expect(!prompt.contains("B13"))
    }

    @Test func aLineHasTheGroupsAggregatesAndNothingElse() {
        let line = SmartPicker.line(for: makeBuckets(1)[0])
        #expect(
            line
                == "B1: quality 4K30, year 2025, source Photos, 400 videos, 120 GB total, about 70 GB could be freed")
        for forbidden in ["/", ".mov", ".MOV", "IMG"] { #expect(!line.contains(forbidden)) }
    }

    @Test func theInstructionsHaveNoExamplesToCopy() {
        let text = SmartPicker.instructions
        #expect(!text.contains("B1"))
        #expect(!text.localizedCaseInsensitiveContains("for example"))
        #expect(text.rangeOfCharacter(from: .decimalDigits) == nil)
    }

    // MARK: Validation

    @Test func onlyIdsFromTheInputAreAccepted() async {
        let (picker, _) = picker(
            returning: SmartPicks(picks: [draft("B99"), draft("Z1"), draft(""), draft("B2"), draft("B1 ")]))
        let outcome = await picker.picks(from: buckets)
        guard case .picks(let picks) = outcome else {
            Issue.record("expected picks")
            return
        }
        #expect(picks.map(\.bucket.id) == ["B2", "B1"])
    }

    @Test func idsAreMatchedForgivingCaseAndPunctuation() async {
        let (picker, _) = picker(returning: SmartPicks(picks: [draft("b3."), draft(" B4: ")]))
        guard case .picks(let picks) = await picker.picks(from: buckets) else {
            Issue.record("expected picks")
            return
        }
        #expect(picks.map(\.bucket.id) == ["B3", "B4"])
    }

    @Test func repeatedGroupsAreDroppedAndAtMostThreeRemain() async {
        let answer = SmartPicks(picks: [draft("B1"), draft("B1"), draft("B2"), draft("B3"), draft("B4"), draft("B5")])
        let (picker, _) = picker(returning: answer)
        guard case .picks(let picks) = await picker.picks(from: buckets) else {
            Issue.record("expected picks")
            return
        }
        #expect(picks.map(\.bucket.id) == ["B1", "B2", "B3"])
    }

    @Test func aGroupNotSentToTheModelIsNotAccepted() async {
        // The library has 40 groups but only twelve were sent: B20 is a real group the model never saw.
        let (picker, _) = picker(returning: SmartPicks(picks: [draft("B20"), draft("B12")]))
        guard case .picks(let picks) = await picker.picks(from: makeBuckets(40)) else {
            Issue.record("expected picks")
            return
        }
        #expect(picks.map(\.bucket.id) == ["B12"])
    }

    @Test func noValidPickFallsBack() async {
        let (picker, _) = picker(returning: SmartPicks(picks: [draft("B77"), draft("nonsense")]))
        #expect(await picker.picks(from: buckets) == .fallback)
        let (empty, _) = self.picker(returning: SmartPicks(picks: []))
        #expect(await empty.picks(from: buckets) == .fallback)
    }

    @Test func titleAndWhyAreCleanedAndANumberTheModelInventedIsReplaced() async {
        let long = String(repeating: "long ", count: 100)
        let answer = SmartPicks(picks: [
            draft("B1", title: "  Big\n\n4K   group  ", why: "This could free about 70 GB from 400 videos."),
            draft("B2", title: "", why: "This would free 900 GB."),
            draft("B3", title: long, why: "540 videos"),
        ])
        let (picker, _) = picker(returning: answer)
        guard case .picks(let picks) = await picker.picks(from: buckets) else {
            Issue.record("expected picks")
            return
        }
        #expect(picks[0].title == "Big 4K group")
        #expect(picks[0].why == "This could free about 70 GB from 400 videos.")
        // Empty title: the group's own. Invented number: the group's own facts.
        #expect(picks[1].title == buckets[1].title)
        #expect(picks[1].why == SmartPicker.factualWhy(for: buckets[1]))
        #expect(picks[2].title.count <= SmartPicker.maximumTitleLength)
        #expect(picks[2].why == SmartPicker.factualWhy(for: buckets[2]))
    }

    // MARK: Failure

    @Test func anUnavailableModelIsNotAskedAndFallsBack() async {
        let client = FakeLanguageModelClient(isAvailable: false, handler: { _, _ in SmartPicks(picks: []) })
        #expect(await SmartPicker(client: client).picks(from: buckets) == .fallback)
        #expect(client.callCount == 0)
    }

    @Test func noGroupsMeansNoRequest() async {
        let (picker, client) = picker(returning: SmartPicks(picks: [draft("B1")]))
        #expect(await picker.picks(from: []) == .fallback)
        #expect(client.callCount == 0)
    }

    @Test func errorsAndATimeoutFallBackSilently() async {
        for error in [AssistantError.guardrail, .contextTooLong, .rateLimited, .unsupportedLanguage, .failed] {
            let client = FakeLanguageModelClient { _, _ in throw error }
            #expect(await SmartPicker(client: client).picks(from: buckets) == .fallback)
        }
        let hung = FakeLanguageModelClient { _, _ in try await hangForever() }
        let started = ContinuousClock.now
        let outcome = await SmartPicker(client: hung, timeout: .milliseconds(100)).picks(from: buckets)
        #expect(outcome == .fallback)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aCancelledRequestIsReportedAndCancelsTheModelCall() async {
        let probe = CancellationProbe()
        let client = FakeLanguageModelClient { _, _ in try await probe.waitUntilCancelled() }
        let picker = SmartPicker(client: client, timeout: .seconds(30))
        let list = buckets
        let task = Task { await picker.picks(from: list) }
        while !probe.started { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(await probe.waitForCancellation())
    }

    // MARK: Filters

    @Test func aGroupsFiltersAreItsQualityItsYearAndNotYetShrunkForLocalFiles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let local = makeBuckets(3)[2]
        #expect(local.library == .localFiles)

        let filters = local.filters(calendar: calendar)

        #expect(filters.quality.qualities == [local.quality])
        #expect(filters.notYetShrunk)
        #expect(filters.since == calendar.date(from: DateComponents(year: local.year, month: 1, day: 1)))
        let end = calendar.date(
            from: DateComponents(year: local.year, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        #expect(filters.until == end)
        #expect(filters.tokens.map(\.kind) == [.quality, .date, .notYetShrunk])
        #expect(makeBuckets(1)[0].filters(calendar: calendar).notYetShrunk == false)
        // A video from the very start and end of the year is inside.
        let range = filters.captureRange
        #expect(
            range?.contains(calendar.date(from: DateComponents(year: local.year, month: 12, day: 31, hour: 22)) ?? .now)
                == true)
    }
}

@MainActor
@Suite struct SmartPicksStoreTests {
    private func rig(available: Bool = true, handler: FakeLanguageModelClient.Handler? = nil)
        -> (SmartPicksStore, FakeLanguageModelClient)
    {
        let client = FakeLanguageModelClient(
            isAvailable: available,
            handler: handler ?? { _, _ in
                SmartPicks(picks: [SmartPickDraft(title: "Start here", why: "It is big.", bucketID: "B1")])
            }
        )
        let availability = AssistantAvailability(client: client, observesActivation: false)
        return (SmartPicksStore(availability: availability, picker: SmartPicker(client: client)), client)
    }

    @Test func picksAreAskedForOnceAndKeptUntilTheKeyChanges() async {
        let (store, client) = rig()
        store.update(buckets: makeBuckets(3), key: 1)
        await store.generateIfNeeded()
        guard case .picks(let picks) = store.state else {
            Issue.record("expected picks")
            return
        }
        #expect(picks.count == 1)
        // The Overview appears again: same key, no new request.
        store.update(buckets: makeBuckets(3), key: 1)
        await store.generateIfNeeded()
        #expect(client.callCount == 1)
        #expect(store.requests == 1)

        // The library or the job outcomes changed: the key changes, so it asks again.
        store.update(buckets: makeBuckets(4), key: 2)
        #expect(store.state == .idle)
        await store.generateIfNeeded()
        #expect(client.callCount == 2)
        #expect(store.buckets.count == 4)
    }

    @Test func aFailedAnswerIsKeptSoTheModelIsNotAskedAgain() async {
        let (store, client) = rig { _, _ in throw AssistantError.guardrail }
        store.update(buckets: makeBuckets(3), key: "a")
        await store.generateIfNeeded()
        #expect(store.state == .fallback)
        #expect(!store.isShowingPicks)
        await store.generateIfNeeded()
        #expect(client.callCount == 1)
        #expect(store.buckets.count == 3)
    }

    @Test func anUnavailableModelIsNeverAskedAndShowsNoPicks() async {
        let (store, client) = rig(available: false)
        store.update(buckets: makeBuckets(3), key: 1)
        await store.generateIfNeeded()
        #expect(client.callCount == 0)
        #expect(store.state == .idle)
        #expect(!store.isShowingPicks)
        #expect(store.buckets.count == 3)
    }

    @Test func theModelGoingAwayHidesPicksAndComingBackAsksOnlyWhenNeeded() async {
        let (store, client) = rig()
        store.update(buckets: makeBuckets(3), key: 1)
        await store.generateIfNeeded()
        #expect(store.isShowingPicks)

        client.isAvailable = false
        store.availability.refresh()
        #expect(!store.isShowingPicks)

        client.isAvailable = true
        store.availability.refresh()
        #expect(store.isShowingPicks)
        await store.generateIfNeeded()
        #expect(client.callCount == 1)
    }

    @Test func noGroupsMeansNoRequest() async {
        let (store, client) = rig()
        store.update(buckets: [], key: 1)
        await store.generateIfNeeded()
        #expect(client.callCount == 0)
        #expect(store.state == .idle)
    }

    @Test func aCancelledRequestChangesNothingAndTheNextOneAsksAgain() async {
        let probe = CancellationProbe()
        let calls = Counter()
        let (store, client) = rig { _, _ in
            if calls.next() == 1 { return try await probe.waitUntilCancelled() }
            return SmartPicks(picks: [SmartPickDraft(title: "T", why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 1)
        let task = Task { await store.generateIfNeeded() }
        while !probe.started { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(store.state == .loading)
        task.cancel()
        await task.value
        #expect(store.state == .idle)

        await store.generateIfNeeded()
        #expect(client.callCount == 2)
        #expect(store.isShowingPicks)
        if case .picks = store.state {} else { Issue.record("expected picks") }
    }

    @Test func newGroupsWhileAskingDiscardTheOldAnswer() async {
        let gate = Counter()
        let (store, _) = rig { _, _ in
            if gate.next() == 1 { try await Task.sleep(for: .milliseconds(150)) }
            return SmartPicks(picks: [SmartPickDraft(title: "T", why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 1)
        let slow = Task { await store.generateIfNeeded() }
        while store.requests == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        store.update(buckets: makeBuckets(5), key: 2)
        await slow.value
        // The slow answer was for the old groups: it must not land on the new ones.
        #expect(store.state == .idle)
        #expect(store.buckets.count == 5)
    }
}

/// Counts calls from concurrent handlers.
private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int {
        value.withLock { count in
            count += 1
            return count
        }
    }
}

@MainActor
@Observable
private final class PicksCollection: MediaCollection {
    var items: [LibraryItem] = [] { didSet { revision += 1 } }
    private(set) var revision = 0
    var isScanning = false
}

@MainActor
@Suite struct ShowBucketTests {
    private func item(_ name: String, height: CGFloat = 2160) -> LibraryItem {
        LibraryItem(
            id: UUID(), source: .photos(name), name: name, byteSize: 800_000_000, duration: 5,
            pixelSize: CGSize(width: height * 16 / 9, height: height), frameRate: 30, captureDate: Date(),
            badges: [], isAvailable: true, inventory: .init())
    }

    private func rig(available: Bool) -> (AssistantSearch, LibraryBrowser, LibraryItem, LibraryItem) {
        let client = FakeLanguageModelClient(isAvailable: available, handler: { _, _ in LibraryQuery() })
        let availability = AssistantAvailability(client: client, observesActivation: false)
        let search = AssistantSearch(availability: availability, translator: QueryTranslator(client: client))
        let collection = PicksCollection()
        let uhd = item("a.mov")
        let hd = item("b.mov", height: 1080)
        collection.items = [uhd, hd]
        return (search, LibraryBrowser(collection: collection), uhd, hd)
    }

    @Test func showAppliesTheBucketsFiltersAsTokensWithoutTheModel() {
        let (search, browser, uhd, hd) = rig(available: false)
        browser.search = "left over"
        browser.selection = [hd.id]
        let bucket = makeBuckets(1)[0]
        let year = Calendar.current.component(.year, from: Date())
        let thisYear = SavingsBucket(
            id: "B1", quality: bucket.quality, year: year, library: .photos, excludesShrunk: false, count: 1,
            bytes: 1, couldFree: 1, itemIDs: [uhd.id])

        search.show(thisYear.filters(), browser: browser, sidebarBadge: nil, shrunkIDs: [])

        #expect(!search.isVisible)
        #expect(search.showsFilters)
        #expect(search.tokens.map(\.kind) == [.quality, .date])
        #expect(search.note.hasPrefix("Showing 4K30 videos"))
        #expect(browser.search.isEmpty)
        #expect(browser.snapshot.items.map(\.id) == [uhd.id])
        // The page's own availability check must not undo it.
        search.availabilityChanged(browser: browser, sidebarBadge: nil)
        #expect(browser.snapshot.items.map(\.id) == [uhd.id])

        // Removing the tokens shows everything again and the filters are gone.
        search.tokensChanged(to: [], browser: browser, sidebarBadge: nil)
        #expect(search.tokens.isEmpty)
        #expect(!search.showsFilters)
        #expect(browser.snapshot.items.count == 2)
    }

    @Test func showHidesTheShrunkVideosOfALocalBucket() {
        let (search, browser, uhd, _) = rig(available: true)
        let local = SavingsBucket(
            id: "B1", quality: .uhd(.fps30), year: Calendar.current.component(.year, from: Date()),
            library: .localFiles, excludesShrunk: true, count: 1, bytes: 1, couldFree: 1, itemIDs: [])

        search.show(local.filters(), browser: browser, sidebarBadge: nil, shrunkIDs: [uhd.id])

        #expect(search.tokens.map(\.kind) == [.quality, .date, .notYetShrunk])
        #expect(browser.snapshot.items.isEmpty)
    }
}

// MARK: - Real model

@Suite struct SmartPicksRealModelTests {
    /// Twelve made-up groups of the kind a large library has.
    private static func synthetic() -> [SavingsBucket] {
        let rows: [(QualityBucket, Int, OverviewSummary.Library, Int, Int, Int)] = [
            (.uhd(.fps60), 2024, .photos, 310, 142, 83), (.uhd(.fps30), 2023, .photos, 540, 118, 69),
            (.uhd(.fps30), 2024, .photos, 220, 64, 38), (.uhd(.fps60), 2023, .localFiles, 35, 41, 24),
            (.uhd(.fps24), 2022, .photos, 90, 30, 18), (.uhd(.fps30), 2021, .photos, 130, 27, 16),
            (.fullHD(.fps60), 2024, .photos, 160, 22, 7), (.uhd(.fps30), 2025, .localFiles, 18, 15, 9),
            (.uhd(.fps60), 2022, .photos, 40, 14, 8), (.fullHD(.fps30), 2023, .photos, 210, 12, 3),
            (.uhd(.fps24), 2025, .photos, 22, 9, 5), (.hd, 2020, .localFiles, 60, 5, 1),
        ]
        return rows.enumerated().map { index, row in
            SavingsBucket(
                id: "B\(index + 1)", quality: row.0, year: row.1, library: row.2, excludesShrunk: row.2 == .localFiles,
                count: row.3, bytes: Int64(row.4) * 1_000_000_000, couldFree: Int64(row.5) * 1_000_000_000,
                itemIDs: [])
        }
    }

    @Test(.enabled(if: SystemLanguageModelClient().isAvailable), .timeLimit(.minutes(1)))
    func realModelPicksOnlyFromTheGroupsItWasGiven() async {
        let buckets = Self.synthetic()
        let outcome = await SmartPicker(client: SystemLanguageModelClient(), timeout: .seconds(40)).picks(from: buckets)
        // A busy or refusing model is fine; what it does answer must be checked.
        if case .picks(let picks) = outcome {
            #expect(!picks.isEmpty && picks.count <= SmartPicker.maximumPicks)
            #expect(Set(picks.map(\.bucket.id)).count == picks.count)
            #expect(picks.allSatisfy { pick in buckets.contains { $0.id == pick.bucket.id } })
            for pick in picks { print("SMART PICK \(pick.bucket.id) | \(pick.title) | \(pick.why)") }
        } else {
            print("SMART PICK outcome: \(outcome)")
        }
    }
}
