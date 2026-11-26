import Testing

@testable import SharedUI

@Test func savingsShowTheAmountAndTheBarWhenThereIsSomethingToFree() {
    let summary = SavingsSummary(couldFree: 600_000_000, totalBytes: 1_000_000_000, availableCount: 3)

    #expect(summary.showsBar)
    #expect(summary.title.hasPrefix("Could free about"))
    #expect(summary.detail.contains("now → about"))
    #expect(summary.afterFraction == 0.4)
}

/// Nothing to free: no bar and no "Zero kB now → about Zero kB after".
@Test func nothingToFreeSaysSoPlainly() {
    let small = SavingsSummary(couldFree: 0, totalBytes: 50_000_000, availableCount: 2)
    #expect(!small.showsBar)
    #expect(small.title == "Nothing to free here")
    #expect(!small.detail.contains("Zero"))
    #expect(!small.detail.contains("→"))
    #expect(small.detail.contains("already small"))

    let none = SavingsSummary(couldFree: 0, totalBytes: 0, availableCount: 0)
    #expect(!none.showsBar)
    #expect(none.title == "Nothing to free here")
    #expect(!none.detail.contains("Zero"))
}

/// Only missing files shown (a drive disconnected): not "already small".
@Test func savingsSaysWhenNoShownVideoIsAvailable() {
    let missing = SavingsSummary(couldFree: 0, totalBytes: 50_000_000, availableCount: 0)
    #expect(!missing.showsBar)
    #expect(missing.detail == "None of these videos are available right now.")
}

@Test func videoCountsLeaveOutTheSizeWhenThereAreNone() {
    #expect(VideoCount.summary(count: 0, bytes: 0) == "0 videos")
    #expect(VideoCount.summary(count: 1, bytes: 0).hasPrefix("1 video · "))
    #expect(VideoCount.summary(count: 3, bytes: 3_000_000).hasPrefix("3 videos · "))
}
