import AarikCore
import Foundation
import Testing

@testable import SharedUI

private func outcome(before: Int64, after: Int64) -> JobOutcome {
    JobOutcome(
        output: URL(fileURLWithPath: "/tmp/a.mov"), bytesBefore: before, bytesAfter: after, report: MetadataReport(),
        replacedOriginal: false)
}

@Test func savedLabelShowsBytesAndPercent() {
    let result = outcome(before: 3_000_000_000, after: 1_000_000_000)
    #expect(ActivityText.saved(result) == "Saved \(ByteFormat.string(2_000_000_000)) (\u{2212}67%)")
    #expect(
        ActivityText.sizeChange(result) == "\(ByteFormat.string(3_000_000_000)) → \(ByteFormat.string(1_000_000_000))")
    #expect(ActivityText.saved(outcome(before: 0, after: 0)) == "Saved \(ByteFormat.string(0))")
}

@Test func notificationBodySummarisesTheRun() {
    let saved = ByteFormat.string(2_100_000_000)
    #expect(
        ActivityText.notificationBody(QueueRunSummary(converted: 3, savedBytes: 2_100_000_000, keptAsIs: 0, failed: 0))
            == "Converted 3 videos · saved \(saved)")
    #expect(
        ActivityText.notificationBody(QueueRunSummary(converted: 1, savedBytes: 2_100_000_000, keptAsIs: 2, failed: 1))
            == "Converted 1 video · saved \(saved) · 2 kept as is · 1 failed")
    #expect(
        ActivityText.notificationBody(QueueRunSummary(converted: 0, savedBytes: 0, keptAsIs: 1, failed: 0))
            == "1 video kept as is")
}

@Test func addNoticeSaysWhatWasSkipped() {
    #expect(ActivityText.addNotice(alreadyQueued: 0, unreadable: 0) == nil)
    #expect(ActivityText.addNotice(alreadyQueued: 1, unreadable: 0) == "1 video is already in the queue.")
    #expect(ActivityText.addNotice(alreadyQueued: 3, unreadable: 0) == "3 videos are already in the queue.")
    #expect(
        ActivityText.addNotice(alreadyQueued: 2, unreadable: 1)
            == "2 videos are already in the queue. 1 video couldn't be added because it's missing or can't be read.")
    #expect(
        ActivityText.addNotice(alreadyQueued: 0, unreadable: 2)
            == "2 videos couldn't be added because they're missing or can't be read.")
}

@Test func addNoticeCountsVideosThatWentMissingBeforeTheyWereAdded() {
    #expect(ActivityText.addNotice(alreadyQueued: 0, unreadable: 0, missing: 0) == nil)
    #expect(
        ActivityText.addNotice(alreadyQueued: 0, unreadable: 0, missing: 1)
            == "1 video couldn't be added because it's missing or can't be read.")
    // A file found missing and one that couldn't be bookmarked are the same to the user.
    #expect(
        ActivityText.addNotice(alreadyQueued: 1, unreadable: 1, missing: 2)
            == "1 video is already in the queue. 3 videos couldn't be added because they're missing or can't be read.")
}

@Test func replaceIsConfirmedOnlyOnceVideosAreAdded() {
    var consent = ReplaceConsent()
    #expect(consent.needsAsking)
    // The user confirms Replace, then cancels the metadata-loss sheet: nothing was added.
    consent.confirm()
    consent.abandon()
    #expect(consent.needsAsking)
    // Confirmed and added: later Replaces in the session don't ask again.
    consent.confirm()
    consent.videosAdded()
    #expect(!consent.needsAsking)
    consent.abandon()
    #expect(!consent.needsAsking)
}

@Test func addingWithoutAConfirmationGrantsNothing() {
    var consent = ReplaceConsent()
    consent.videosAdded()
    #expect(consent.needsAsking)
}
