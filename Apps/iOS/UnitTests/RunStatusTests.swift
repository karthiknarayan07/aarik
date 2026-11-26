import AppCore
import Foundation
import Testing

@testable import iOSApp

/// The Live Activity and the continued-processing task show the real stage of the run: downloading from iCloud, then
/// converting. A queued or running video never reads as finished.
@MainActor
struct RunStatusTests {
    private func job(
        _ name: String, state: JobState = .queued, phase: String? = nil
    ) -> Job {
        Job(
            toolID: "convert", source: URL(filePath: "/tmp/\(name).mov"), sourceBookmark: Data(), settings: Data(),
            state: state, phase: phase)
    }

    private func finished(_ name: String) -> Job {
        job(name, state: .keptAsIs(reason: "done", code: .other))
    }

    private let notPaused = QueuePause(isPausedByUser: false, automatic: nil)

    @Test func theLiveActivityIsDownloadingWhileTheICloudDownloadRuns() {
        let jobs = [job("a", state: .running(progress: 0.42), phase: "Downloading from iCloud…")]
        let state = LiveActivityController.makeState(jobs: jobs, pause: notPaused, runBaselineFinished: 0)
        #expect(state.status == .downloading)
        #expect(state.detail == "Downloading from iCloud · 42%")
        #expect(state.itemsRemaining == 1)
        #expect(state.totalItems == 1)
        #expect(LiveActivityText.title(for: state) == "Converting 1 Video")
        #expect(LiveActivityText.subtitle(for: state) == "Downloading from iCloud · 42%")
    }

    @Test func theLiveActivityIsDownloadingWhileTheICloudGateWaits() {
        // One download runs at a time; the next video waits its turn, and that is still the download stage.
        let jobs = [job("a", state: .running(progress: 0), phase: "Waiting for another download…")]
        let state = LiveActivityController.makeState(jobs: jobs, pause: notPaused, runBaselineFinished: 0)
        #expect(state.status == .downloading)
        #expect(state.detail == "Waiting for another download · 0%")
    }

    @Test func itSwitchesToConvertingWhenTheDownloadIsDone() {
        let jobs = [job("a", state: .running(progress: 0.63), phase: "Converting…")]
        let state = LiveActivityController.makeState(jobs: jobs, pause: notPaused, runBaselineFinished: 0)
        #expect(state.status == .running)
        #expect(state.detail == "Converting · 63%")
        #expect(abs(state.progress - 0.63) < 0.0001)
    }

    @Test func aRunnerWithoutPhasesReadsAsConverting() {
        let jobs = [job("a", state: .running(progress: 0.5))]
        let state = LiveActivityController.makeState(jobs: jobs, pause: notPaused, runBaselineFinished: 0)
        #expect(state.status == .running)
        #expect(state.detail == "Converting · 50%")
    }

    @Test func aWaitingVideoKeepsTheRunGoingAndIsNeverFinished() {
        let jobs = [
            finished("done"), job("a", state: .running(progress: 0.1), phase: "Downloading from iCloud…"), job("b"),
        ]
        let state = LiveActivityController.makeState(jobs: jobs, pause: notPaused, runBaselineFinished: 0)
        #expect(state.status == .downloading)
        #expect(state.itemsRemaining == 2)
        #expect(state.totalItems == 3)
        #expect(LiveActivityText.title(for: state) == "Converting 3 Videos")
    }

    @Test func videosOnlyQueuedStillShowAsAnActiveRun() {
        let state = LiveActivityController.makeState(
            jobs: [job("a"), job("b")], pause: notPaused, runBaselineFinished: 0)
        #expect(state.status == .running)
        #expect(state.detail == "Waiting to start")
        #expect(state.itemsRemaining == 2)
    }

    @Test func historyBeforeTheRunDoesNotCountTowardItsTotal() {
        let jobs = [finished("old1"), finished("old2"), job("a", state: .running(progress: 0.5), phase: "Converting…")]
        let state = LiveActivityController.makeState(jobs: jobs, pause: notPaused, runBaselineFinished: 2)
        #expect(state.totalItems == 1)
        #expect(LiveActivityText.title(for: state) == "Converting 1 Video")
    }

    @Test func heatPausesStillShowTheirOwnState() {
        let jobs = [job("a", state: .running(progress: 0.5), phase: "Downloading from iCloud…")]
        let hot = QueuePause(isPausedByUser: false, automatic: .thermal)
        #expect(
            LiveActivityController.makeState(jobs: jobs, pause: hot, runBaselineFinished: 0).status == .waitingThermal)
    }

    @Test func aLowBatteryWarnsAndKeepsRunning() {
        let jobs = [job("a", state: .running(progress: 0.5), phase: "Converting…")]
        let low = QueuePause(isPausedByUser: false, automatic: nil, lowBattery: true)
        let state = LiveActivityController.makeState(jobs: jobs, pause: low, runBaselineFinished: 0)
        #expect(state.status == .running)
        #expect(state.lowBattery)
        #expect(LiveActivityText.subtitle(for: state) == "Battery is low. Converting uses more power.")
    }

    @Test func theSystemTaskSaysTheStageInItsTitleAndSubtitle() {
        let jobs = [job("a", state: .running(progress: 0.42), phase: "Downloading from iCloud…"), job("b")]
        let run = RunStatus(jobs: jobs, runBaselineFinished: 0)
        #expect(run.title == "Converting 2 Videos")
        #expect(run.subtitle == "1 of 2 · Downloading from iCloud · 42%")
        #expect(run.isDownloading)
        let single = RunStatus(jobs: [jobs[0]], runBaselineFinished: 0)
        #expect(single.title == "Converting 1 Video")
        #expect(single.subtitle == "Downloading from iCloud · 42%")
    }

    @Test func noWordingNamesATool() {
        let jobs = [job("a", state: .running(progress: 0.5), phase: "Converting…")]
        let state = LiveActivityController.makeState(jobs: jobs, pause: notPaused, runBaselineFinished: 0)
        for text in [LiveActivityText.title(for: state), LiveActivityText.subtitle(for: state)] {
            #expect(!text.localizedCaseInsensitiveContains("shrink"))
        }
        let done = ConvertActivityAttributes.ContentState(
            itemsRemaining: 0, totalItems: 2, progress: 1, savedBytes: 1, status: .finished)
        #expect(!LiveActivityText.title(for: done).localizedCaseInsensitiveContains("shrink"))
    }
}
