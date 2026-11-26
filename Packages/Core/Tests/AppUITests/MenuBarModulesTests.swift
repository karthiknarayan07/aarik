import AppCore
import Foundation
import Testing

@testable import AppUI

/// The wording and enabled states of the menu bar popover's modules.
@Suite struct MenuBarModulesTests {
    private static func job(_ state: JobState) -> Job {
        Job(toolID: "test", source: URL(filePath: "/a.mov"), sourceBookmark: Data(), settings: Data(), state: state)
    }

    private static func modules(_ states: [JobState], paused: Bool = false) -> MenuBarModules {
        MenuBarModules(activity: ActivitySummary(jobs: states.map(job)), isPaused: paused)
    }

    @Test func aRunningJobFillsTheRing() {
        let modules = Self.modules([.running(progress: 0.4), .queued, .queued])
        #expect(modules.isRunning)
        #expect(modules.ringValue == 0.4)
        #expect(modules.ringCaption == "Converting")
        #expect(modules.queueCaption == "3 videos in the queue")
        #expect(modules.pauseTitle == "Pause")
        #expect(modules.isPauseEnabled)
    }

    @Test func anEmptyQueueIsIdleAndHasNothingToPause() {
        let modules = Self.modules([])
        #expect(!modules.isRunning)
        #expect(modules.ringValue == 0)
        #expect(modules.ringCaption == "Idle")
        #expect(modules.queueCaption == "Queue is empty")
        #expect(!modules.isPauseEnabled)
    }

    @Test func aPausedQueueCanBeResumed() {
        let modules = Self.modules([.queued], paused: true)
        #expect(modules.ringCaption == "Paused")
        #expect(modules.queueCaption == "1 video in the queue")
        #expect(modules.pauseTitle == "Resume")
        #expect(modules.pauseSymbol == "play.fill")
        #expect(modules.isPauseEnabled)
        #expect(Self.modules([], paused: true).isPauseEnabled, "resuming an empty paused queue is still allowed")
    }
}
