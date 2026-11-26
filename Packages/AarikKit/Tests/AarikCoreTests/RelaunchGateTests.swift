import Foundation
import Testing

@testable import AppCore

private func job(_ state: JobState) -> Job {
    Job(
        toolID: "fake", source: URL(fileURLWithPath: "/tmp/a.mov"), sourceBookmark: Data(), settings: Data(),
        state: state)
}

@MainActor
@Suite("Relaunch gate")
struct RelaunchGateTests {
    @Test func idleQueueDoesNotPostpone() {
        let gate = RelaunchGate()
        gate.update(jobs: [job(.failed(reason: "x")), job(.keptAsIs(reason: "y"))], isQueuePaused: false)
        var ran = 0
        #expect(!gate.postpone { ran += 1 })
        #expect(ran == 0)
    }

    @Test func runningJobPostponesEvenWhenPaused() {
        #expect(RelaunchGate.isBusy(jobs: [job(.running(progress: 0.2))], isQueuePaused: true))
    }

    @Test func waitingJobsPostponeUnlessPaused() {
        #expect(RelaunchGate.isBusy(jobs: [job(.queued)], isQueuePaused: false))
        #expect(!RelaunchGate.isBusy(jobs: [job(.queued)], isQueuePaused: true))
    }

    @Test func heldRelaunchRunsOnceWhenQueueBecomesIdle() {
        let gate = RelaunchGate()
        gate.update(jobs: [job(.running(progress: 0.5)), job(.queued)], isQueuePaused: false)
        var ran = 0
        #expect(gate.postpone { ran += 1 })
        gate.update(jobs: [job(.queued)], isQueuePaused: false)
        #expect(ran == 0)
        gate.update(jobs: [], isQueuePaused: false)
        #expect(ran == 1)
        gate.update(jobs: [], isQueuePaused: false)
        #expect(ran == 1)
    }

    @Test func pausingReleasesAHeldRelaunchWhenNothingRuns() {
        let gate = RelaunchGate()
        gate.update(jobs: [job(.queued)], isQueuePaused: false)
        var ran = 0
        #expect(gate.postpone { ran += 1 })
        gate.update(jobs: [job(.queued)], isQueuePaused: true)
        #expect(ran == 1)
    }
}
