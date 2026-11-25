import AppCore
import Foundation
import Testing

@testable import AppUI

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
