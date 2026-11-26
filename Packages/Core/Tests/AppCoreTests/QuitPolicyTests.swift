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

    @Test func eitherSignalMeansTheSessionIsEnding() {
        let now = Date(timeIntervalSince1970: 1_000)
        let shutdown = QuitPolicy.fourCC("shut")
        let plain = QuitPolicy.fourCC("quia")
        let recent = now.addingTimeInterval(-5)
        let stale = now.addingTimeInterval(-31)
        func ending(_ code: UInt32?, _ announced: Date?) -> Bool {
            QuitPolicy.isSessionEnding(quitReason: code, powerOffAnnouncedAt: announced, now: now)
        }
        // reason only, announcement only, both
        #expect(ending(shutdown, nil))
        #expect(ending(nil, recent))
        #expect(ending(shutdown, recent))
        // neither, or a plain quit with no announcement
        #expect(!ending(nil, nil))
        #expect(!ending(plain, nil))
        // a plain quit right after an announcement is still the system's (the announcement is the signal)
        #expect(ending(plain, recent))
        // an old announcement (a cancelled shutdown) no longer counts; the reason still does
        #expect(!ending(nil, stale))
        #expect(!ending(plain, stale))
        #expect(ending(shutdown, stale))
        // the window's edges, and a clock that moved backwards
        #expect(ending(nil, now.addingTimeInterval(-QuitPolicy.powerOffWindow)))
        #expect(!ending(nil, now.addingTimeInterval(-QuitPolicy.powerOffWindow - 1)))
        #expect(!ending(nil, now.addingTimeInterval(10)))
    }

    @Test func explanationFollowsAutoStartAndHeldQueue() {
        let normal = QuitPolicy.explanation(appName: "App", queueStartsAutomatically: true, automaticPause: nil)
        #expect(normal.contains("continue the next time you open App."))
        let off = QuitPolicy.explanation(appName: "App", queueStartsAutomatically: false, automaticPause: nil)
        #expect(off.contains("wait for you to resume the queue"))
        #expect(!off.contains("continue the next time"))
        let hot = QuitPolicy.explanation(appName: "App", queueStartsAutomatically: true, automaticPause: .thermal)
        #expect(hot.contains("cooled down"))
        let low = QuitPolicy.explanation(appName: "App", queueStartsAutomatically: true, automaticPause: .batteryLow)
        #expect(low.contains("plugged in"))
        // Auto-start off wins: nothing starts by itself, whatever the Mac's state.
        let both = QuitPolicy.explanation(appName: "App", queueStartsAutomatically: false, automaticPause: .thermal)
        #expect(both == off)
    }

    private func outcome() -> JobOutcome {
        JobOutcome(
            output: URL(fileURLWithPath: "/tmp/o.mov"), bytesBefore: 2, bytesAfter: 1, report: MetadataReport(),
            replacedOriginal: false)
    }
}
