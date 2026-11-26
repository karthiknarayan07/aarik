import Testing

@testable import AppUI

@Suite struct JobListActionsTests {
    private let file = JobRowFacts(hasFile: true)
    private let photo = JobRowFacts(hasFile: false)
    private let running = JobRowFacts(isRunning: true, hasFile: true)

    private func actions(_ kind: JobListKind, _ rows: [JobRowFacts]) -> [JobListAction] {
        JobListActions.contextMenu(kind: kind, rows: rows).map(\.action)
    }

    @Test func noSelectionHasNoMenuAndNoDefaultAction() {
        for kind in JobListKind.allCases {
            #expect(JobListActions.contextMenu(kind: kind, rows: []).isEmpty)
            #expect(JobListActions.primary(kind: kind, rows: []) == nil)
            #expect(JobListActions.deleteAction(kind: kind, rows: []) == nil)
        }
    }

    @Test func theQueueRevealsRemovesAndCancels() {
        #expect(actions(.queue, [file]) == [.showInFinder, .removeFromQueue])
        #expect(JobListActions.contextMenu(kind: .queue, rows: [file]).last?.title == "Remove from Queue")
        #expect(JobListActions.contextMenu(kind: .queue, rows: [running]).last?.title == "Cancel Conversion")
        #expect(JobListActions.contextMenu(kind: .queue, rows: [running, file]).last?.title == "Remove from Queue")
        #expect(JobListActions.deleteAction(kind: .queue, rows: [running]) == .removeFromQueue)
    }

    @Test func aPhotosVideoHasNoFileToReveal() {
        #expect(actions(.queue, [photo]) == [.removeFromQueue])
        #expect(actions(.completed, [file, photo]) == [.removeFromList])
        #expect(JobListActions.primary(kind: .completed, rows: [photo]) == nil)
        #expect(JobListActions.primary(kind: .queue, rows: [photo]) == nil)
    }

    @Test func finishedListsRevealAndOnlyDropTheRow() {
        for kind in [JobListKind.completed, .keptAsIs] {
            #expect(actions(kind, [file, file]) == [.showInFinder, .removeFromList])
            #expect(JobListActions.deleteAction(kind: kind, rows: [file]) == .removeFromList)
            #expect(JobListActions.primary(kind: kind, rows: [file]) == .showInFinder)
        }
    }

    @Test func failedVideosCanBeRetriedAndARowWithoutAFileRetriesOnDoubleClick() {
        #expect(actions(.failed, [file]) == [.retry, .showInFinder, .removeFromList])
        #expect(actions(.failed, [photo]) == [.retry, .removeFromList])
        #expect(JobListActions.primary(kind: .failed, rows: [file]) == .showInFinder)
        #expect(JobListActions.primary(kind: .failed, rows: [photo]) == .retry)
    }

    @Test func menuTitlesAreTitleCase() {
        for kind in JobListKind.allCases {
            for command in JobListActions.contextMenu(kind: kind, rows: [file, running]) {
                let words = command.title.split(separator: " ")
                #expect(words.allSatisfy { $0.first?.isUppercase == true || ["in", "from"].contains($0) }, "\(command.title)")
            }
        }
    }

    @Test func subtitlesSayHowManyAndWhatTheListSavedOrWaitsFor() {
        #expect(
            JobListActions.subtitle(kind: .queue, count: 3, savedBytes: 0, pauseText: "Paused") == "3 videos · Paused")
        #expect(JobListActions.subtitle(kind: .queue, count: 1, savedBytes: 0, pauseText: nil) == "1 video")
        #expect(JobListActions.subtitle(kind: .queue, count: 0, savedBytes: 0, pauseText: "Paused") == "Paused")
        #expect(
            JobListActions.subtitle(kind: .completed, count: 2, savedBytes: 1_000_000_000, pauseText: nil)
                == "2 videos · Saved \(ByteFormat.string(1_000_000_000))")
        #expect(JobListActions.subtitle(kind: .failed, count: 4, savedBytes: 0, pauseText: nil) == "4 videos")
        #expect(JobListActions.subtitle(kind: .completed, count: 0, savedBytes: 0, pauseText: nil) == "")
    }
}
