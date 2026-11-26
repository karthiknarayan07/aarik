import AarikCore
import SharedUI
import CoreGraphics
import Convert
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

private func draft(_ id: String, why: String = "They take a lot of room.") -> SmartPickDraft {
    SmartPickDraft(why: why, bucketID: id)
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

    @Test func theTitleIsAlwaysTheGroupsOwnAndAnInventedNumberInTheReasonIsReplaced() async {
        let answer = SmartPicks(picks: [
            draft("B1", why: "Biggest 4K60 savings: this could free about 70 GB from 400 videos."),
            draft("B2", why: "This would free 900 GB."), draft("B3", why: "540 videos"),
        ])
        let (picker, _) = picker(returning: answer)
        guard case .picks(let picks) = await picker.picks(from: buckets) else {
            Issue.record("expected picks")
            return
        }
        // The model can't name a group: what the row says is what Show filters by.
        #expect(picks.map(\.title) == buckets.prefix(3).map(\.title))
        #expect(picks.map(\.id) == buckets.prefix(3).map(\.identity))
        // "60" is not on B1's line (its quality is 4K30), so the sentence is replaced.
        #expect(picks[0].why == SmartPicker.factualWhy(for: buckets[0]))
        #expect(picks[1].why == SmartPicker.factualWhy(for: buckets[1]))
        #expect(picks[2].why == SmartPicker.factualWhy(for: buckets[2]))
    }

    @Test func aReasonThatEchoesPartOfTheGroupsLineFallsBackToTheFactualSentence() {
        let bucket = makeBuckets(1)[0]
        let echoes = [
            "Quality 4K30, year 2025, source Photos.",
            "It is source Photos with lots of room.",
            "There are 400 videos, 120 GB total in this group.",
            "From year 2025 with plenty of space to win back.",
            "B1 is the one to start with because it is big.",
            "About 70 GB could be freed here.",
        ]
        for echo in echoes { #expect(!SmartPicker.isGrounded(echo, in: bucket), "\(echo)") }
        #expect(SmartPicker.isGrounded("Converting these could free about 70 GB from 400 videos.", in: bucket))
        #expect(SmartPicker.isGrounded("They take a lot of room and shrink well.", in: bucket))
    }

    @Test func aReasonClaimingSmallestOrLowestFallsBack() {
        let bucket = makeBuckets(1)[0]
        for claim in [
            "These are the smallest files, so shrinking them is easy.",
            "The lowest quality group has plenty to give back.",
            "Smallest: they would free about 70 GB.",
        ] {
            #expect(!SmartPicker.isGrounded(claim, in: bucket), "\(claim)")
        }
        #expect(SmartPicker.isGrounded("They take a lot of room and shrink well.", in: bucket))
    }

    @Test func aPickKeepsTheFactualSentenceWhenTheModelEchoesTheLine() async {
        let (picker, _) = picker(
            returning: SmartPicks(picks: [draft("B1", why: "Quality 4K30, year 2025, source Photos."), draft("B2")]))
        guard case .picks(let picks) = await picker.picks(from: buckets) else {
            Issue.record("expected picks")
            return
        }
        #expect(picks[0].why == SmartPicker.factualWhy(for: buckets[0]))
        #expect(picks[1].why == "They take a lot of room.")
    }

    @Test func aPhotosGroupAndALocalFilesGroupNeverShareATitle() {
        let photos = SavingsBucket(
            id: "B1", quality: .uhd(.fps60), year: 2024, library: .photos, excludesShrunk: false, count: 1, bytes: 1,
            couldFree: 1, itemIDs: [])
        let files = SavingsBucket(
            id: "B2", quality: .uhd(.fps60), year: 2024, library: .localFiles, excludesShrunk: true, count: 1,
            bytes: 1, couldFree: 1, itemIDs: [])
        #expect(photos.title == "4K60 from 2024 \u{00B7} Photos")
        #expect(files.title == "4K60 from 2024 \u{00B7} Local Files")
        #expect(photos.title != files.title)
        let picks = [photos, files].map { SmartPick(bucket: $0, why: SmartPicker.factualWhy(for: $0)) }
        #expect(Set(picks.map(\.title)).count == 2)
    }

    @Test func aGroundedReasonIsKeptAndBucketIdentitiesDoNotDependOnRank() {
        let list = makeBuckets(3)
        #expect(Set(list.map(\.identity)).count == 3)
        let moved = SavingsBucket(
            id: "B9", quality: list[0].quality, year: list[0].year, library: list[0].library,
            excludesShrunk: list[0].excludesShrunk, count: list[0].count, bytes: list[0].bytes,
            couldFree: list[0].couldFree, itemIDs: [])
        #expect(moved.identity == list[0].identity)
        #expect(SmartPicker.isGrounded("This could free about 70 GB from 400 videos.", in: list[0]))
        // A copy of the line is not a reason.
        #expect(!SmartPicker.isGrounded(SmartPicker.line(for: list[0]), in: list[0]))
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
    private let clock = ManualClock()
    private static let debounce = Duration.seconds(5)

    private func rig(
        available: Bool = true, maximumStaleness: Duration = .seconds(60), retryAfter: Duration = .seconds(300),
        handler: FakeLanguageModelClient.Handler? = nil
    ) -> (SmartPicksStore, FakeLanguageModelClient) {
        let client = FakeLanguageModelClient(
            isAvailable: available,
            handler: handler ?? { _, _ in
                SmartPicks(picks: [SmartPickDraft(why: "It is big.", bucketID: "B1")])
            }
        )
        let availability = AssistantAvailability(client: client, observesActivation: false)
        let store = SmartPicksStore(
            availability: availability, picker: SmartPicker(client: client), debounce: Self.debounce,
            maximumStaleness: maximumStaleness, retryAfter: retryAfter, clock: clock.smartPicksClock)
        return (store, client)
    }

    /// Asks for a refresh that waits for the groups to be quiet, lets the quiet period pass, and waits for it.
    private func refresh(_ store: SmartPicksStore) async {
        let task = Task { await store.generateIfNeeded() }
        await clock.waitForSleepers()
        clock.advance(by: Self.debounce)
        await task.value
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
        // The picks stay on screen; they are refreshed in the background.
        if case .picks = store.state {} else { Issue.record("picks were cleared") }
        await refresh(store)
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
            return SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 1)
        let task = Task { await store.generateIfNeeded() }
        while !probe.started { await Task.yield() }
        #expect(store.state == .loading)
        task.cancel()
        await task.value
        #expect(store.state == .idle)

        await store.generateIfNeeded()
        #expect(client.callCount == 2)
        #expect(store.isShowingPicks)
        if case .picks = store.state {} else { Issue.record("expected picks") }
    }

    @Test func newGroupsWhileTheFirstRequestRunsDiscardTheOldAnswer() async {
        let gate = Gate()
        let calls = Counter()
        let (store, _) = rig { _, _ in
            if calls.next() == 1 { await gate.pass() }
            return SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 1)
        let slow = Task { await store.generateIfNeeded() }
        await gate.waitUntilEntered()
        store.update(buckets: makeBuckets(5), key: 2)
        gate.open()
        await slow.value
        // The slow answer was for the old groups: it must not land on the new ones.
        #expect(store.state == .idle)
        #expect(store.buckets.count == 5)
    }

    @Test func shownPicksStayWhileTheGroupsChangeAndAreRefreshedAfterTheyAreQuiet() async {
        let (store, client) = rig { _, _ in
            SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1"), SmartPickDraft(why: "W", bucketID: "B2")])
        }
        store.update(buckets: makeBuckets(4), key: 1)
        await store.generateIfNeeded()
        #expect(client.callCount == 1)

        // Jobs finish: groups change three times in a row, a second apart.
        var refresh: Task<Void, Never>?
        for key in 2...4 {
            refresh?.cancel()
            store.update(buckets: makeBuckets(4), key: key)
            // Never a spinner or an empty state: the same two rows, immediately.
            guard case .picks(let shown) = store.state else {
                Issue.record("picks were replaced by \(store.state)")
                return
            }
            #expect(shown.count == 2)
            refresh = Task { await store.generateIfNeeded() }
            await clock.waitForSleepers()
            clock.advance(by: .seconds(1))
        }
        // Still inside the quiet period: the model was not asked again.
        #expect(client.callCount == 1)
        clock.advance(by: Self.debounce)
        await refresh?.value
        #expect(client.callCount == 2)
        guard case .picks(let after) = store.state else {
            Issue.record("expected picks")
            return
        }
        #expect(after.count == 2)
    }

    @Test func aRefreshIsNotStarvedWhileTheGroupsKeepChanging() async {
        let (store, client) = rig(maximumStaleness: .seconds(12)) { _, _ in
            SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 0)
        await store.generateIfNeeded()
        let firstChange = clock.now
        var refresh: Task<Void, Never>?
        for key in 1...20 {
            refresh?.cancel()
            store.update(buckets: makeBuckets(3), key: key)
            refresh = Task { await store.generateIfNeeded() }
            await clock.waitForSleepers()
            // Changes come every two seconds, faster than the five-second quiet period.
            clock.advance(by: .seconds(2))
            if clock.sleeperCount == 0 { break }
        }
        await refresh?.value
        // The model was asked once the 12 s cap passed, and only once.
        #expect(client.callCount == 2)
        #expect(clock.now - firstChange == .seconds(12))
    }

    @Test func aPickWhoseGroupIsGoneDisappearsAtOnceAndTheOthersTakeTheNewNumbers() async {
        let (store, _) = rig { _, _ in
            SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1"), SmartPickDraft(why: "W", bucketID: "B2")])
        }
        let list = makeBuckets(4)
        store.update(buckets: list, key: 1)
        await store.generateIfNeeded()
        guard case .picks(let first) = store.state, first.count == 2 else {
            Issue.record("expected two picks")
            return
        }

        // B1's group is gone; B2's group has moved to rank 1 with new numbers.
        let b2 = list[1]
        let moved = SavingsBucket(
            id: "B1", quality: b2.quality, year: b2.year, library: b2.library, excludesShrunk: b2.excludesShrunk,
            count: b2.count + 3, bytes: b2.bytes, couldFree: b2.couldFree + 1_000_000_000, itemIDs: [UUID()])
        store.update(buckets: [moved] + list.dropFirst(2), key: 2)

        guard case .picks(let now) = store.state else {
            Issue.record("expected picks")
            return
        }
        #expect(now.map(\.id) == [b2.identity])
        #expect(now.first?.bucket == moved)
        #expect(store.current(list[0]) == nil)
        #expect(store.current(b2) == moved)
        // The sentence stays only while it is true; "W" is not a sentence, so the group's own facts show.
        #expect(now.first?.why == SmartPicker.factualWhy(for: moved))
    }

    @Test func whenEveryPickIsGoneThereIsNoOldRowLeft() async {
        let (store, _) = rig { _, _ in SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")]) }
        let list = makeBuckets(4)
        store.update(buckets: list, key: 1)
        await store.generateIfNeeded()
        store.update(buckets: Array(list.dropFirst()), key: 2)
        #expect(store.state == .idle)
    }

    @Test func aFailedFirstAnswerIsTriedAgainAfterAWhileButNotBefore() async {
        let calls = Counter()
        let (store, client) = rig(retryAfter: .seconds(300)) { _, _ in
            if calls.next() == 1 { throw AssistantError.rateLimited }
            return SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 1)
        await store.generateIfNeeded()
        #expect(store.state == .fallback)
        await store.generateIfNeeded()
        #expect(client.callCount == 1)

        clock.advance(by: .seconds(299))
        await store.generateIfNeeded()
        #expect(client.callCount == 1)

        clock.advance(by: .seconds(1))
        await store.generateIfNeeded()
        #expect(client.callCount == 2)
        #expect(store.isShowingPicks)
        if case .picks = store.state {} else { Issue.record("expected picks") }
    }

    @Test func afterAFallbackChangedGroupsDoNotAskTheModelBeforeRetryAfter() async {
        let calls = Counter()
        let (store, client) = rig(retryAfter: .seconds(300)) { _, _ in
            if calls.next() == 1 { throw AssistantError.guardrail }
            return SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 1)
        await store.generateIfNeeded()
        #expect(store.state == .fallback)

        // The groups change again and again, as a running queue changes them.
        for key in 2...5 {
            clock.advance(by: .seconds(30))
            store.update(buckets: makeBuckets(3 + key), key: key)
            await store.generateIfNeeded()
        }
        #expect(client.callCount == 1)
        #expect(store.state == .fallback)
        #expect(store.buckets.count == 8)

        // Once the retry time has passed the groups as they are now are asked about.
        // They have been stale for longer than the cap, so there is no quiet period left to wait for.
        clock.advance(by: .seconds(200))
        await store.generateIfNeeded()
        #expect(client.callCount == 2)
        #expect(store.isShowingPicks)
    }

    @Test func aFailedRefreshKeepsThePicksShownAndTheModelIsLeftAloneBeforeRetryAfter() async {
        let calls = Counter()
        let (store, client) = rig(retryAfter: .seconds(300)) { _, _ in
            if calls.next() > 1 { throw AssistantError.guardrail }
            return SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")])
        }
        store.update(buckets: makeBuckets(3), key: 1)
        await store.generateIfNeeded()
        store.update(buckets: makeBuckets(3), key: 2)
        await refresh(store)
        #expect(client.callCount == 2)
        if case .picks = store.state {} else { Issue.record("picks were dropped") }
        // Not asked again until the groups change again.
        await store.generateIfNeeded()
        #expect(client.callCount == 2)
        // They change again, but the model has just failed: still not asked.
        store.update(buckets: makeBuckets(3), key: 3)
        await store.generateIfNeeded()
        #expect(client.callCount == 2)
        if case .picks = store.state {} else { Issue.record("picks were dropped") }
    }

    @Test func nothingToShowAfterAFailureIsNotASpinner() async {
        let calls = Counter()
        let (store, _) = rig { _, _ in
            if calls.next() > 1 { throw AssistantError.guardrail }
            return SmartPicks(picks: [SmartPickDraft(why: "W", bucketID: "B1")])
        }
        let list = makeBuckets(4)
        store.update(buckets: list, key: 1)
        await store.generateIfNeeded()
        store.update(buckets: list, key: 2)
        await refresh(store)
        // The shown pick's group is gone and the model has just failed.
        store.update(buckets: Array(list.dropFirst()), key: 3)
        #expect(store.state == .idle)
        await store.generateIfNeeded()
        #expect(store.state == .fallback)
        #expect(!store.isShowingPicks)
    }

    @Test func theCountOfUndatedVideosIsKeptWithTheGroups() {
        let (store, _) = rig()
        store.update(buckets: makeBuckets(2), undatedCount: 12, key: 1)
        #expect(store.undatedCount == 12)
        store.update(buckets: makeBuckets(2), undatedCount: 0, key: 2)
        #expect(store.undatedCount == 0)
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

@Suite struct AddToQueueResolutionTests {
    private func item(available: Bool = true) -> LibraryItem {
        LibraryItem(
            id: UUID(), source: .photos("x"), name: "x", byteSize: 1, duration: 1,
            pixelSize: CGSize(width: 3840, height: 2160), frameRate: 30, captureDate: Date(), badges: [],
            isAvailable: available, inventory: .init())
    }

    @Test func idsThatAreGoneOrNoLongerAvailableAreSkippedAtClickTime() {
        let kept = item()
        let gone = item()
        let unavailable = item(available: false)
        let bucket = SavingsBucket(
            id: "B1", quality: .uhd(.fps30), year: 2024, library: .photos, excludesShrunk: false, count: 3, bytes: 3,
            couldFree: 3, itemIDs: [kept.id, gone.id, unavailable.id])

        #expect(bucket.availableItemIDs(in: [kept, unavailable]) == [kept.id])
        #expect(bucket.availableItemIDs(in: []).isEmpty)
        #expect(bucket.availableItemIDs(in: [kept, gone, unavailable]) == [kept.id, gone.id])
    }
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
