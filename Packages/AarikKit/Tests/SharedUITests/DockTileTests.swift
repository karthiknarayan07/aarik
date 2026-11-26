import AppCore
import Foundation
import Testing

@testable import AppUI

@Suite struct DockTileTests {
    private func job(_ name: String, _ state: JobState) -> Job {
        Job(
            toolID: "t", source: URL(filePath: "/tmp/\(name)"), sourceBookmark: Data(), settings: Data(), state: state)
    }

    private func state(_ jobs: [Job]) -> DockTileState {
        DockTileState(jobs: jobs, name: { $0.source.lastPathComponent })
    }

    private let outcome = JobOutcome(
        output: URL(filePath: "/tmp/o.mov"), bytesBefore: 2, bytesAfter: 1, report: MetadataReport(),
        replacedOriginal: false)

    @Test func theBadgeCountsWaitingVideosNotTheRunningOne() {
        let jobs = [
            job("a", .running(progress: 0.4)), job("b", .queued), job("c", .queued),
            job("d", .completed(outcome)), job("e", .failed(reason: "x")), job("f", .keptAsIs(reason: "y")),
        ]
        let tile = state(jobs)

        #expect(tile.waitingCount == 2)
        #expect(tile.badge == "2")
        #expect(tile.progress == 0.4)
        #expect(tile.runningName == "a")
    }

    @Test func noBadgeWhenNothingWaitsAndNoBarWhenNothingRuns() {
        let tile = state([job("a", .running(progress: 0.1)), job("b", .completed(outcome))])
        #expect(tile.badge == nil)
        #expect(tile.isRunning)

        let idle = state([job("a", .completed(outcome))])
        #expect(idle.badge == nil)
        #expect(idle.progress == nil)
        #expect(!idle.isRunning)
        #expect(state([]).badge == nil)
    }

    @Test func aPausedQueueKeepsItsBadgeAndHasNoBar() {
        let tile = state([job("a", .queued), job("b", .queued), job("c", .queued)])
        #expect(tile.badge == "3")
        #expect(tile.progress == nil)
    }

    @Test func progressIsClampedAndTheBadgeIsCapped() {
        #expect(state([job("a", .running(progress: 1.5))]).progress == 1)
        #expect(state([job("a", .running(progress: -1))]).progress == 0)
        let many = (0..<1000).map { job("v\($0)", .queued) }
        #expect(state(many).badge == "999+")
        #expect(state(Array(many.prefix(999))).badge == "999")
    }

    @Test func theDockMenuHasQueueCommandsAndAStatusLineWhileBusy() {
        let tile = state([job("IMG_1.MOV", .running(progress: 0.42)), job("b", .queued)])
        let items = DockMenu.items(for: tile, isPaused: false)

        #expect(items.map(\.kind) == [.status, .separator, .pauseOrResume, .showQueue, .addVideos])
        #expect(items[0].title == "Converting IMG_1.MOV · 42% · 1 video waiting")
        #expect(!items[0].isEnabled)
        #expect(items[2].title == "Pause Queue")
        #expect(items[2].isEnabled)
        #expect(items[3].title == "Show Queue")
        #expect(items[4].title == "Add Videos…")
    }

    @Test func anIdleQueueHasNoStatusAndNothingToPause() {
        let items = DockMenu.items(for: state([]), isPaused: false)

        #expect(items.map(\.kind) == [.pauseOrResume, .showQueue, .addVideos])
        #expect(!items[0].isEnabled)
    }

    @Test func aPausedQueueOffersResume() {
        let items = DockMenu.items(for: state([job("a", .queued)]), isPaused: true)

        #expect(items[0].title == "Queue paused · 1 video waiting")
        #expect(items[2].title == "Resume Queue")
        #expect(items[2].isEnabled)
        #expect(DockMenu.items(for: state([]), isPaused: true).first?.title == "Queue paused")
    }
}
