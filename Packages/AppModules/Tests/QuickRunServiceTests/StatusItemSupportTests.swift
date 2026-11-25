import AppKit
import Foundation
import Testing

@testable import QuickRunService

@Suite struct StatusItemSupportTests {
    @Test func theNameAloneDecidesWhileDragging() {
        #expect(MovieDropFilter.looksLikeMovie(URL(filePath: "/nowhere/a.mov")))
        #expect(MovieDropFilter.looksLikeMovie(URL(filePath: "/nowhere/B.MP4")))
        #expect(!MovieDropFilter.looksLikeMovie(URL(filePath: "/nowhere/a.jpg")))
        #expect(!MovieDropFilter.looksLikeMovie(URL(filePath: "/nowhere/noextension")))
        #expect(!MovieDropFilter.looksLikeMovie(URL(filePath: "/nowhere/folder.mov/", directoryHint: .isDirectory)))
        #expect(!MovieDropFilter.looksLikeMovie(URL(string: "https://example.com/a.mov")!))
        #expect(
            MovieDropFilter.mightContainMovie([URL(filePath: "/x/a.jpg"), URL(filePath: "/x/b.mov")]))
        #expect(!MovieDropFilter.mightContainMovie([]))
    }

    @Test func aDragSessionIsJudgedOnce() {
        var cache = DragVerdictCache()
        var calls = 0
        func judge(_ session: Int, _ answer: Bool) -> Bool {
            cache.verdict(forSession: session) {
                calls += 1
                return answer
            }
        }
        #expect(judge(7, true))
        // Later updates of the same drag reuse the answer, even if asked to recompute.
        #expect(judge(7, false))
        #expect(judge(7, false))
        #expect(calls == 1)
        // A new drag is judged afresh.
        #expect(!judge(8, false))
        #expect(calls == 2)
        cache.reset()
        #expect(judge(8, true))
        #expect(calls == 3)
    }

    @Test func aPointerClickDoesNotActivateButKeyboardAndAssistiveOpensDo() {
        #expect(!PopoverActivation.shouldActivate(openedBy: .leftMouseUp))
        #expect(!PopoverActivation.shouldActivate(openedBy: .leftMouseDown))
        #expect(!PopoverActivation.shouldActivate(openedBy: .rightMouseDown))
        #expect(PopoverActivation.shouldActivate(openedBy: .keyDown))
        #expect(PopoverActivation.shouldActivate(openedBy: nil))
    }

    @Test func statusTextFollowsTheRun() {
        #expect(QuickRunStatus(phase: .checking(files: 3)).text == "Checking 3 videos…")
        #expect(QuickRunStatus(phase: .running(videos: 3)).text == "Shrinking 3 videos…")
        #expect(QuickRunStatus(phase: .running(videos: 1)).text == "Shrinking 1 video…")
        let mixed = QuickRunTally(converted: 2, skipped: 1, failed: 0)
        let done = QuickRunStatus(phase: .finished(mixed))
        #expect(done.text == "Done: 2 shrunk, 1 skipped")
        #expect(done.skippedCount == 1)
        #expect(!done.isActive)
        #expect(QuickRunStatus(phase: .running(videos: 2)).isActive)
        #expect(
            QuickRunStatus(phase: .finished(QuickRunTally(converted: 0, skipped: 0, failed: 0))).text
                == "Done: nothing to shrink")
        #expect(
            QuickRunStatus(phase: .finished(QuickRunTally(converted: 1, skipped: 0, failed: 2))).text
                == "Done: 1 shrunk, 2 failed")
    }

    @Test func aMenuBarRunIsAnnouncedUnlessThePopoverIsOpen() {
        for active in [true, false] {
            for window in [true, false] {
                #expect(
                    !NotificationPolicy.shouldPost(
                        origin: .statusItem, appIsActive: active, windowOnScreen: window, popoverVisible: true))
                #expect(
                    NotificationPolicy.shouldPost(
                        origin: .statusItem, appIsActive: active, windowOnScreen: window, popoverVisible: false))
            }
        }
    }

    @Test func otherRunsKeepTheWindowRule() {
        #expect(
            !NotificationPolicy.shouldPost(
                origin: .background, appIsActive: true, windowOnScreen: true, popoverVisible: false))
        #expect(
            NotificationPolicy.shouldPost(
                origin: .background, appIsActive: true, windowOnScreen: false, popoverVisible: false))
    }
}
