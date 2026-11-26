import Foundation
import Testing

@testable import QuickRunService

@Suite struct MenuBarRunBoardTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func tally(_ converted: Int, _ skipped: Int = 0, _ failed: Int = 0) -> QuickRunTally {
        QuickRunTally(converted: converted, skipped: skipped, failed: failed)
    }

    /// A run that has been checked and queued with `count` jobs.
    private func queuedRun(_ board: inout MenuBarRunBoard, count: Int = 2) -> (entry: UUID, run: UUID, jobs: [UUID]) {
        let entry = board.begin(files: count)
        board.checked(entry, movies: count, rejected: 0, now: start)
        let run = UUID()
        let jobs = (0..<count).map { _ in UUID() }
        board.queued(entry, runID: run, jobIDs: jobs, skipped: 0, now: start, popoverVisible: false)
        return (entry, run, jobs)
    }

    @Test func aRunGoesFromCheckingToShrinkingToDone() {
        var board = MenuBarRunBoard()
        let entry = board.begin(files: 3)
        #expect(board.lines == ["Checking 3 videos…"])
        board.checked(entry, movies: 2, rejected: 0, now: start)
        #expect(board.lines == ["Checking 2 videos…"])
        let run = UUID()
        board.queued(entry, runID: run, jobIDs: [UUID(), UUID()], skipped: 1, now: start, popoverVisible: false)
        #expect(board.lines == ["Shrinking 2 videos…"])
        #expect(board.isActive)
        board.finished(runID: run, tally: tally(2, 1), now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 2 shrunk, 1 skipped"])
        #expect(!board.isActive)
        #expect(board.reviewRunIDs == [run])
    }

    @Test func twoOverlappingRunsKeepBothResults() {
        var board = MenuBarRunBoard()
        let first = queuedRun(&board)
        board.finished(runID: first.run, tally: tally(2), now: start, popoverVisible: false)
        // A second drop starts while the first one's result hasn't been seen.
        let second = board.begin(files: 4)
        #expect(board.lines == ["Checking 4 videos…", "Done: 2 shrunk"])
        board.checked(second, movies: 4, rejected: 0, now: start)
        let run = UUID()
        board.queued(second, runID: run, jobIDs: [UUID(), UUID()], skipped: 2, now: start, popoverVisible: false)
        #expect(board.lines == ["Shrinking 2 videos…", "Done: 2 shrunk"])
        board.finished(runID: run, tally: tally(1, 1, 0), now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 3 shrunk, 1 skipped"])
        #expect(board.reviewRunIDs == [run])
    }

    @Test func twoRunsGoingAtOnceAddUp() {
        var board = MenuBarRunBoard()
        let first = queuedRun(&board, count: 2)
        let second = queuedRun(&board, count: 3)
        #expect(board.lines == ["Shrinking 5 videos…"])
        board.finished(runID: second.run, tally: tally(3), now: start, popoverVisible: false)
        #expect(board.lines == ["Shrinking 2 videos…", "Done: 3 shrunk"])
        board.finished(runID: first.run, tally: tally(1, 0, 1), now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 4 shrunk, 1 failed"])
    }

    @Test func aDropWithNothingValidLeavesAnActiveRunAlone() {
        var board = MenuBarRunBoard()
        let first = queuedRun(&board, count: 3)
        let junk = board.begin(files: 1)
        board.checked(junk, movies: 0, rejected: 0, now: start)
        #expect(board.lines == ["Shrinking 3 videos…"])
        #expect(board.notice?.text == "Nothing to shrink")
        #expect(board.entries.map(\.id) == [first.entry])
    }

    @Test func rejectedItemsAreReportedAsSkippedNotDroppedSilently() {
        var board = MenuBarRunBoard()
        let none = board.begin(files: 2)
        board.checked(none, movies: 0, rejected: 2, now: start)
        #expect(board.notice?.text == "Nothing to shrink, 2 skipped")
        // Mixed: they count in the run's tally.
        let entry = board.begin(files: 3)
        board.checked(entry, movies: 1, rejected: 2, now: start)
        let run = UUID()
        board.queued(entry, runID: run, jobIDs: [UUID()], skipped: 0, now: start, popoverVisible: false)
        board.finished(runID: run, tally: tally(1), now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 1 shrunk, 2 skipped"])
        // Nothing of those can be reviewed in the window: no run holds them.
        #expect(board.reviewRunIDs.isEmpty)
    }

    @Test func theBriefMessageGoesByItself() {
        var board = MenuBarRunBoard()
        let entry = board.begin(files: 1)
        board.checked(entry, movies: 0, rejected: 0, now: start)
        board.prune(now: start.addingTimeInterval(MenuBarRunBoard.noticeLifetime - 1))
        #expect(board.notice != nil)
        board.prune(now: start.addingTimeInterval(MenuBarRunBoard.noticeLifetime))
        #expect(board.notice == nil)
        #expect(board.isEmpty)
    }

    @Test func aFinishedNoticeThatArrivesFirstStillEndsTheStatus() {
        var board = MenuBarRunBoard()
        let entry = board.begin(files: 2)
        board.checked(entry, movies: 2, rejected: 0, now: start)
        let run = UUID()
        // The run ended inside `QuickRun.run` (everything skipped), before the receipt came back.
        board.finished(runID: run, tally: tally(0, 2), now: start, popoverVisible: false)
        #expect(board.lines == ["Checking 2 videos…"])
        board.queued(entry, runID: run, jobIDs: [], skipped: 2, now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 2 skipped"])
        #expect(!board.isActive)
    }

    @Test func aNoticeBeforeTheReceiptOfARunWithJobsAlsoEndsIt() {
        var board = MenuBarRunBoard()
        let entry = board.begin(files: 1)
        let run = UUID()
        board.finished(runID: run, tally: tally(1), now: start, popoverVisible: false)
        board.queued(entry, runID: run, jobIDs: [UUID()], skipped: 0, now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 1 shrunk"])
    }

    @Test func aRunWithNothingQueuedIsDoneEvenWithoutANotice() {
        var board = MenuBarRunBoard()
        let entry = board.begin(files: 1)
        board.queued(entry, runID: UUID(), jobIDs: [], skipped: 1, now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 1 skipped"])
    }

    @Test func theDoneLineClearsAfterTenMinutes() {
        var board = MenuBarRunBoard()
        let run = queuedRun(&board)
        board.finished(runID: run.run, tally: tally(2), now: start, popoverVisible: false)
        board.prune(now: start.addingTimeInterval(MenuBarRunBoard.doneLifetime - 1))
        #expect(board.lines == ["Done: 2 shrunk"])
        board.prune(now: start.addingTimeInterval(MenuBarRunBoard.doneLifetime))
        #expect(board.lines.isEmpty)
        #expect(board.entries.isEmpty)
    }

    @Test func theDoneLineClearsWhenThePopoverOpensAgainAfterItWasSeen() {
        var board = MenuBarRunBoard()
        let run = queuedRun(&board)
        board.finished(runID: run.run, tally: tally(2), now: start, popoverVisible: false)
        // First opening: the person sees the result, which stays while the popover is open.
        board.popoverOpened(now: start.addingTimeInterval(5))
        #expect(board.lines == ["Done: 2 shrunk"])
        // The next opening finds it already seen.
        board.popoverOpened(now: start.addingTimeInterval(60))
        #expect(board.lines.isEmpty)
    }

    @Test func aResultThatFinishedWhileThePopoverWasOpenCountsAsSeen() {
        var board = MenuBarRunBoard()
        let run = queuedRun(&board)
        board.finished(runID: run.run, tally: tally(2), now: start, popoverVisible: true)
        board.popoverOpened(now: start.addingTimeInterval(60))
        #expect(board.lines.isEmpty)
    }

    @Test func aRunStillGoingSurvivesOpeningThePopover() {
        var board = MenuBarRunBoard()
        _ = queuedRun(&board)
        board.popoverOpened(now: start)
        board.popoverOpened(now: start.addingTimeInterval(60))
        #expect(board.lines == ["Shrinking 2 videos…"])
    }

    @Test func aRunWhoseJobsWereAllRemovedIsCleared() {
        var board = MenuBarRunBoard()
        let run = queuedRun(&board)
        board.dropStale(presentJobs: [run.jobs[0]])
        #expect(board.isActive)
        board.dropStale(presentJobs: [UUID()])
        #expect(board.entries.isEmpty)
    }

    @Test func aFinishedRunIsNotClearedAsStale() {
        var board = MenuBarRunBoard()
        let run = queuedRun(&board)
        board.finished(runID: run.run, tally: tally(2), now: start, popoverVisible: false)
        board.dropStale(presentJobs: [])
        #expect(board.lines == ["Done: 2 shrunk"])
    }

    @Test func nothingConvertedSaysSo() {
        var board = MenuBarRunBoard()
        let run = queuedRun(&board)
        board.finished(runID: run.run, tally: tally(0), now: start, popoverVisible: false)
        #expect(board.lines == ["Done: nothing to shrink"])
        board.popoverOpened(now: start)
        board.popoverOpened(now: start)
        let failing = queuedRun(&board)
        board.finished(runID: failing.run, tally: tally(1, 0, 2), now: start, popoverVisible: false)
        #expect(board.lines == ["Done: 1 shrunk, 2 failed"])
    }
}
