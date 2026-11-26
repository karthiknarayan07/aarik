import AarikCore
import Convert
import Foundation
import Testing

@testable import QuickRunService

@Suite struct QuickRunTests {
    private struct Harness {
        let fixture: QuickRunFixture
        let queue = FakeQueue()
        let notifier = FakeNotifier()
        let clock = FakeClock()
        let store: QuickRunStore
        let quickRun: QuickRun

        init(
            sources: (QuickRunFixture) throws -> [URL: QuickRunSource],
            settings: QuickRunSettings = QuickRunSettings(preset: .balanced, saveLocation: SaveLocation())
        ) throws {
            fixture = try QuickRunFixture()
            let clock = self.clock
            store = QuickRunStore(fileURL: fixture.storeURL, now: clock.now)
            quickRun = QuickRun(
                queue: queue, store: store, notifier: notifier, inspector: FakeInspector(sources: try sources(fixture)),
                settings: { settings }, now: { clock.now })
        }
    }

    private func settings(of job: Job) throws -> ConvertJobSettings {
        try JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
    }

    @Test func aFileThatWouldLoseMetadataIsSkippedNotQueued() async throws {
        var clean: URL!
        var lossy: URL!
        let harness = try Harness { fixture in
            clean = try fixture.file("clean.mov")
            lossy = try fixture.file("lossy.mov")
            return [clean: QuickRunFixture.clean, lossy: QuickRunFixture.lossy]
        }
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [clean, lossy], overrides: nil)

        #expect(receipt.queuedJobIDs.count == 1)
        #expect(receipt.skipped.map(\.url) == [lossy])
        #expect(receipt.skipped.first?.reason.contains("Cinematic depth data") == true)
        let jobs = await harness.queue.jobs
        #expect(jobs.map(\.source) == [clean])
    }

    @Test func aKeptAsIsOutcomeIsSkippedWithItsReason() async throws {
        var small: URL!
        let harness = try Harness { fixture in
            small = try fixture.file("small.mov")
            return [small: QuickRunFixture.small]
        }
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [small], overrides: nil)

        #expect(receipt.queuedJobIDs.isEmpty)
        #expect(receipt.skipped == [QuickRunSkip(url: small, reason: "Already small")])
        #expect(await harness.queue.jobs.isEmpty)
    }

    @Test func theNoticeCarriesTheRunsOriginAndTally() async throws {
        var small: URL!
        let harness = try Harness { fixture in
            small = try fixture.file("small.mov")
            return [small: QuickRunFixture.small]
        }
        defer { harness.fixture.remove() }

        _ = await harness.quickRun.run(urls: [small], overrides: nil, origin: .statusItem)

        let notice = try #require(await harness.notifier.notices.first)
        #expect(notice.origin == .statusItem)
        #expect(notice.tally == QuickRunTally(converted: 0, skipped: 1, failed: 0))
    }

    @Test func recordsSavedWithoutAnOriginAreBackgroundRuns() throws {
        let json = """
            {"runID":"\(UUID().uuidString)","createdAt":0,"jobIDs":[],"skipped":[],"notes":[]}
            """
        let record = try JSONDecoder().decode(QuickRunRecord.self, from: Data(json.utf8))
        #expect(record.origin == .background)
    }

    @Test func unreadableFilesAreSkipped() async throws {
        var missing: URL!
        let harness = try Harness { fixture in
            missing = fixture.directory.appending(path: "gone.mov")
            return [:]
        }
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [missing], overrides: nil)

        #expect(receipt.skipped.map(\.url) == [missing])
        #expect(receipt.queuedJobIDs.isEmpty)
    }

    @Test func replaceIsNeverUsedAndTheReceiptSaysSo() async throws {
        var clean: URL!
        var replace = SaveLocation()
        replace.choice = .replace
        let harness = try Harness(
            sources: { fixture in
                clean = try fixture.file("clean.mov")
                return [clean: QuickRunFixture.clean]
            }, settings: QuickRunSettings(preset: .balanced, saveLocation: replace))
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [clean], overrides: nil)

        let job = try #require(await harness.queue.jobs.first)
        #expect(try settings(of: job).saveTo == .nextToOriginal)
        #expect(receipt.notes.count == 1)
        #expect(receipt.notes.first?.contains("next to the original") == true)

        // The note is in the notification too.
        await harness.queue.completeAll()
        await harness.quickRun.refresh()
        let body = try #require(await harness.notifier.notices.first?.body)
        #expect(body.contains("next to the original"))
    }

    @Test func overridesWinOverTheSavedPreset() async throws {
        var clean: URL!
        let harness = try Harness { fixture in
            clean = try fixture.file("clean.mov")
            return [clean: QuickRunFixture.clean]
        }
        defer { harness.fixture.remove() }

        _ = await harness.quickRun.run(urls: [clean], overrides: QuickRunOverrides(preset: .smaller))

        let job = try #require(await harness.queue.jobs.first)
        #expect(try settings(of: job).preset == .smaller)
    }

    @Test func receiptBookkeepingMatchesTheQueueAndTheStore() async throws {
        var first: URL!
        var second: URL!
        let harness = try Harness { fixture in
            first = try fixture.file("a.mov")
            second = try fixture.file("b.mov")
            return [first: QuickRunFixture.clean, second: QuickRunFixture.clean]
        }
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [first, second, first], overrides: nil)

        let jobs = await harness.queue.jobs
        #expect(Set(receipt.queuedJobIDs) == Set(jobs.map(\.id)))
        #expect(receipt.queuedJobIDs.count == 2)
        #expect(receipt.skipped.isEmpty)
        let record = try #require(harness.store.run(receipt.runID))
        #expect(record.jobIDs == receipt.queuedJobIDs)
        #expect(await harness.queue.resumeCount == 1)

        // The same files again while they wait: nothing new is queued, and each is reported.
        let again = await harness.quickRun.run(urls: [first], overrides: nil)
        #expect(again.queuedJobIDs.isEmpty)
        #expect(again.skipped == [QuickRunSkip(url: first, reason: "Already in the queue")])
        #expect(await harness.queue.jobs.count == 2)
    }

    @Test func theNotificationFiresOncePerRunWhenEveryJobIsDone() async throws {
        var first: URL!
        var second: URL!
        var lossy: URL!
        let harness = try Harness { fixture in
            first = try fixture.file("a.mov")
            second = try fixture.file("b.mov")
            lossy = try fixture.file("c.mov")
            return [first: QuickRunFixture.clean, second: QuickRunFixture.clean, lossy: QuickRunFixture.lossy]
        }
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [first, second, lossy], overrides: nil)
        await harness.quickRun.refresh()
        #expect(await harness.notifier.notices.isEmpty)

        let ids = receipt.queuedJobIDs
        let queue = harness.queue
        let jobs = await queue.jobs
        await queue.finish(ids[0], with: .completed(FakeQueue.outcome(for: jobs[0], saving: 500_000_000)))
        await harness.quickRun.refresh()
        #expect(await harness.notifier.notices.isEmpty)

        await queue.finish(ids[1], with: .completed(FakeQueue.outcome(for: jobs[1], saving: 700_000_000)))
        await harness.quickRun.refresh()
        await harness.quickRun.refresh()
        let notices = await harness.notifier.notices
        #expect(notices.count == 1)
        #expect(notices.first?.runID == receipt.runID)
        #expect(notices.first?.body == "2 converted, saved 1.2 GB. 1 skipped.")
    }

    @Test func eachRunsNotificationCountsOnlyItsOwnFiles() async throws {
        var first: URL!
        var second: URL!
        let harness = try Harness { fixture in
            first = try fixture.file("a.mov")
            second = try fixture.file("b.mov")
            return [first: QuickRunFixture.clean, second: QuickRunFixture.clean]
        }
        defer { harness.fixture.remove() }

        let one = await harness.quickRun.run(urls: [first], overrides: nil)
        let two = await harness.quickRun.run(urls: [second], overrides: nil)
        let queue = harness.queue
        let jobs = await queue.jobs
        await queue.finish(jobs[0].id, with: .completed(FakeQueue.outcome(for: jobs[0], saving: 1000)))
        await queue.finish(jobs[1].id, with: .failed(reason: "boom"))
        await harness.quickRun.refresh()

        let notices = await harness.notifier.notices
        #expect(notices.map(\.runID) == [one.runID, two.runID])
        #expect(notices[0].body.hasPrefix("1 converted"))
        #expect(!notices[0].body.contains("failed"))
        #expect(notices[1].body == "1 failed.")
    }

    @Test func finishedJobsRemovedFromTheQueueStillCount() async throws {
        var first: URL!
        var second: URL!
        let harness = try Harness { fixture in
            first = try fixture.file("a.mov")
            second = try fixture.file("b.mov")
            return [first: QuickRunFixture.clean, second: QuickRunFixture.clean]
        }
        defer { harness.fixture.remove() }

        _ = await harness.quickRun.run(urls: [first, second], overrides: nil)
        let queue = harness.queue
        let jobs = await queue.jobs
        await queue.finish(jobs[0].id, with: .completed(FakeQueue.outcome(for: jobs[0], saving: 500_000_000)))
        await harness.quickRun.refresh()
        // "Clear completed" in the window, then the second job fails.
        await queue.remove(jobs[0].id)
        await queue.finish(jobs[1].id, with: .failed(reason: "boom"))
        await harness.quickRun.refresh()

        #expect(await harness.notifier.notices.first?.body == "1 converted, saved 500 MB. 1 failed.")
    }

    @Test func aRunWhoseJobsWereAllRemovedBeforeFinishingStaysSilent() async throws {
        var first: URL!
        let harness = try Harness { fixture in
            first = try fixture.file("a.mov")
            return [first: QuickRunFixture.clean]
        }
        defer { harness.fixture.remove() }

        _ = await harness.quickRun.run(urls: [first], overrides: nil)
        let job = try #require(await harness.queue.jobs.first)
        await harness.queue.remove(job.id)
        await harness.quickRun.refresh()

        #expect(await harness.notifier.notices.isEmpty)
    }

    @Test func aRunWithNothingToConvertNotifiesAtOnce() async throws {
        var small: URL!
        let harness = try Harness { fixture in
            small = try fixture.file("small.mov")
            return [small: QuickRunFixture.small]
        }
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [small], overrides: nil)
        await harness.quickRun.refresh()

        let notices = await harness.notifier.notices
        #expect(notices.map(\.runID) == [receipt.runID])
        #expect(notices.first?.body == "1 skipped.")
    }

    @Test func aKeptAsIsJobCountsAsSkippedAndIsListedForReview() async throws {
        var first: URL!
        let harness = try Harness { fixture in
            first = try fixture.file("a.mov")
            return [first: QuickRunFixture.clean]
        }
        defer { harness.fixture.remove() }

        let receipt = await harness.quickRun.run(urls: [first], overrides: nil)
        let job = try #require(await harness.queue.jobs.first)
        await harness.queue.finish(job.id, with: .keptAsIs(reason: "Would save less than 10%"))
        await harness.quickRun.refresh()

        #expect(await harness.notifier.notices.first?.body == "1 skipped.")
        #expect(await harness.quickRun.skippedURLs(runID: receipt.runID) == [first])
    }

    @Test func runsRestoredFromDiskStillNotify() async throws {
        var first: URL!
        let harness = try Harness { fixture in
            first = try fixture.file("a.mov")
            return [first: QuickRunFixture.clean]
        }
        defer { harness.fixture.remove() }
        let receipt = await harness.quickRun.run(urls: [first], overrides: nil)

        // A new launch: the store is read back, the queue still holds the finished job.
        let reloaded = QuickRunStore(fileURL: harness.fixture.storeURL, now: harness.clock.now)
        let notifier = FakeNotifier()
        let clock = harness.clock
        let relaunched = QuickRun(
            queue: harness.queue, store: reloaded, notifier: notifier, inspector: FakeInspector(sources: [:]),
            settings: { QuickRunSettings(preset: .balanced, saveLocation: SaveLocation()) }, now: { clock.now })
        await harness.queue.completeAll()
        await relaunched.refresh()

        #expect(await notifier.notices.map(\.runID) == [receipt.runID])
        #expect(await harness.notifier.notices.isEmpty)
    }
}

@Suite struct QuickRunWatcherTests {
    @Test func theWatcherNotifiesWhenTheQueueFinishesAJob() async throws {
        let fixture = try QuickRunFixture()
        defer { fixture.remove() }
        let url = try fixture.file("a.mov")
        let queue = FakeQueue()
        let notifier = FakeNotifier()
        let quickRun = QuickRun(
            queue: queue, store: QuickRunStore(fileURL: fixture.storeURL), notifier: notifier,
            inspector: FakeInspector(sources: [url: QuickRunFixture.clean]),
            settings: { QuickRunSettings(preset: .balanced, saveLocation: SaveLocation()) })
        await quickRun.start()
        _ = await quickRun.run(urls: [url], overrides: nil)

        await queue.completeAll()

        for _ in 0..<200 where await notifier.notices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await notifier.notices.count == 1)
    }
}

@Suite struct QuickRunStoreTests {
    @Test func runsPersistAndRunsOlderThanSevenDaysArePrunedAtLaunch() throws {
        let fixture = try QuickRunFixture()
        defer { fixture.remove() }
        let clock = FakeClock()
        let store = QuickRunStore(fileURL: fixture.storeURL, now: clock.now)
        let old = QuickRunRecord(runID: UUID(), createdAt: clock.now, jobIDs: [UUID()], skipped: [], notes: [])
        store.add(old)
        clock.advance(days: 6)
        let recent = QuickRunRecord(
            runID: UUID(), createdAt: clock.now, jobIDs: [UUID()],
            skipped: [QuickRunSkip(url: URL(filePath: "/tmp/x.mov"), reason: "Already small")], notes: [])
        store.add(recent)

        // Six days in, both are kept across a relaunch.
        let sixDays = QuickRunStore(fileURL: fixture.storeURL, now: clock.now)
        #expect(Set(sixDays.runs.map(\.runID)) == [old.runID, recent.runID])

        clock.advance(days: 2)
        let relaunched = QuickRunStore(fileURL: fixture.storeURL, now: clock.now)
        #expect(relaunched.runs.map(\.runID) == [recent.runID])
        #expect(relaunched.runs.first?.skipped.first?.reason == "Already small")
        #expect(relaunched.jobIDs == Set(recent.jobIDs))
    }

    @Test func aFileWrittenBeforeResultsExistedStillLoads() throws {
        let fixture = try QuickRunFixture()
        defer { fixture.remove() }
        let runID = UUID()
        let jobID = UUID()
        let old = """
            [{"runID":"\(runID.uuidString)","createdAt":\(Date().timeIntervalSinceReferenceDate),
              "jobIDs":["\(jobID.uuidString)"],"skipped":[{"url":"file:///tmp/x.mov","reason":"Already small"}],
              "notes":[],"notified":false}]
            """
        try Data(old.utf8).write(to: fixture.storeURL)

        let record = try #require(QuickRunStore(fileURL: fixture.storeURL).run(runID))

        #expect(record.jobIDs == [jobID])
        #expect(record.results.isEmpty)
        #expect(record.skipped.first?.reason == "Already small")
    }

    @Test func markingNotifiedWorksOnce() throws {
        let fixture = try QuickRunFixture()
        defer { fixture.remove() }
        let store = QuickRunStore(fileURL: fixture.storeURL)
        let record = QuickRunRecord(runID: UUID(), createdAt: Date(), jobIDs: [], skipped: [], notes: [])
        store.add(record)

        #expect(store.markNotified(record.runID))
        #expect(!store.markNotified(record.runID))
        #expect(QuickRunStore(fileURL: fixture.storeURL).run(record.runID)?.notified == true)
    }
}
