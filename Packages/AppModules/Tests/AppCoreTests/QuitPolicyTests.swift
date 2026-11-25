import Foundation
import Testing

@testable import AppCore

private func job(_ state: JobState) -> Job {
    Job(
        toolID: "fake", source: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"), sourceBookmark: Data(),
        settings: Data(), state: state)
}

@Suite("Quit confirmation")
struct QuitPolicyTests {
    @Test func asksWhileAJobRuns() {
        #expect(
            QuitPolicy.needsConfirmation(
                jobs: [job(.running(progress: 0.3)), job(.queued)], isQueuePaused: false, isSessionEnding: false))
    }

    @Test func asksWhileAJobFinishesAfterAPause() {
        #expect(
            QuitPolicy.needsConfirmation(
                jobs: [job(.running(progress: 0.3))], isQueuePaused: true, isSessionEnding: false))
    }

    @Test func asksWhenWaitingJobsAreAboutToStart() {
        #expect(QuitPolicy.needsConfirmation(jobs: [job(.queued)], isQueuePaused: false, isSessionEnding: false))
    }

    @Test func doesNotAskWhenIdle() {
        let finished = [job(.completed(outcome())), job(.failed(reason: "x")), job(.keptAsIs(reason: "y"))]
        #expect(!QuitPolicy.needsConfirmation(jobs: [], isQueuePaused: false, isSessionEnding: false))
        #expect(!QuitPolicy.needsConfirmation(jobs: finished, isQueuePaused: false, isSessionEnding: false))
    }

    @Test func doesNotAskWhenPausedWithNothingRunning() {
        #expect(!QuitPolicy.needsConfirmation(jobs: [job(.queued)], isQueuePaused: true, isSessionEnding: false))
    }

    @Test func doesNotAskDuringLogoutRestartOrShutdown() {
        #expect(
            !QuitPolicy.needsConfirmation(
                jobs: [job(.running(progress: 0.3)), job(.queued)], isQueuePaused: false, isSessionEnding: true))
    }

    @Test func recognizesTheQuitReasonsOfAnEndingSession() {
        for code in ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"] {
            #expect(QuitPolicy.isSessionEnding(quitReason: QuitPolicy.fourCC(code)), "\(code)")
        }
    }

    @Test func aPlainQuitOrNoReasonIsTheUsers() {
        #expect(!QuitPolicy.isSessionEnding(quitReason: QuitPolicy.fourCC("quia")))
        #expect(!QuitPolicy.isSessionEnding(quitReason: nil))
        #expect(!QuitPolicy.isSessionEnding(quitReason: 0))
    }

    private func outcome() -> JobOutcome {
        JobOutcome(
            output: URL(fileURLWithPath: "/tmp/o.mov"), bytesBefore: 2, bytesAfter: 1, report: MetadataReport(),
            replacedOriginal: false)
    }
}
