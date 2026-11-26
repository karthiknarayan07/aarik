import AarikCore
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import QuickRunService

@Suite struct MovieDropFilterTests {
    @Test func movieTypesPassAndTheRestDont() {
        #expect(MovieDropFilter.isMovie(contentType: .quickTimeMovie, isDirectory: false, isPackage: false))
        #expect(MovieDropFilter.isMovie(contentType: .mpeg4Movie, isDirectory: false, isPackage: false))
        #expect(!MovieDropFilter.isMovie(contentType: .jpeg, isDirectory: false, isPackage: false))
        #expect(!MovieDropFilter.isMovie(contentType: nil, isDirectory: false, isPackage: false))
        // A folder or a package named like a movie is not one.
        #expect(!MovieDropFilter.isMovie(contentType: .quickTimeMovie, isDirectory: true, isPackage: false))
        #expect(!MovieDropFilter.isMovie(contentType: .movie, isDirectory: false, isPackage: true))
    }

    @Test func filtersRealFilesKeepingOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "movie-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "a.mov")
        let second = folder.appending(path: "b.mp4")
        let photo = folder.appending(path: "c.jpg")
        let subfolder = folder.appending(path: "d.mov", directoryHint: .isDirectory)
        for file in [first, second, photo] { try Data([0]).write(to: file) }
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let missing = folder.appending(path: "gone.mov")

        let kept = MovieDropFilter.movies(
            in: [second, photo, subfolder, missing, URL(string: "https://example.com/x.mov")!, first])

        #expect(kept == [second, first])
    }

    @Test func readsMoviesFromAPasteboard() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "movie-pb-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appending(path: "a.mov")
        let note = folder.appending(path: "b.txt")
        for file in [movie, note] { try Data([0]).write(to: file) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([movie as NSURL, note as NSURL])

        #expect(MovieDropFilter.movies(on: pasteboard).map(\.lastPathComponent) == ["a.mov"])
    }

    @Test func anEmptyPasteboardHasNoMovies() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(MovieDropFilter.movies(on: pasteboard).isEmpty)
    }
}

@Suite struct MenuBarPreferenceTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "menu-bar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func isOnByDefaultAndFollowsTheSetting() {
        let defaults = makeDefaults()
        #expect(MenuBarPreference.isShown(defaults))
        defaults.set(false, forKey: MenuBarPreference.key)
        #expect(!MenuBarPreference.isShown(defaults))
        defaults.set(true, forKey: MenuBarPreference.key)
        #expect(MenuBarPreference.isShown(defaults))
        defaults.removeObject(forKey: MenuBarPreference.key)
        #expect(MenuBarPreference.isShown(defaults))
    }
}

@Suite struct StatusIconStateTests {
    @Test func idleWhenNothingIsQueued() {
        let state = StatusIconState(queueCount: 0, runningProgress: nil, isPaused: false)
        #expect(state == .idle)
        #expect(state.symbolName == "film.stack")
        #expect(state.variableValue == nil)
        #expect(StatusIconState(queueCount: 0, runningProgress: nil, isPaused: true) == .idle)
    }

    @Test func aRunningJobShowsItsProgress() {
        let state = StatusIconState(queueCount: 3, runningProgress: 0.4, isPaused: false)
        #expect(state == .running(progress: 0.4))
        #expect(state.symbolName == "progress.indicator")
        #expect(state.variableValue == 0.4)
        #expect(state.accessibilityStatus == "Converting, 40 percent")
    }

    @Test func progressIsClamped() {
        #expect(StatusIconState(queueCount: 1, runningProgress: 1.7, isPaused: false) == .running(progress: 1))
        #expect(StatusIconState(queueCount: 1, runningProgress: -0.2, isPaused: false) == .running(progress: 0))
    }

    @Test func aPausedQueueWithWaitingJobsShowsPause() {
        let state = StatusIconState(queueCount: 2, runningProgress: nil, isPaused: true)
        #expect(state == .paused(waiting: 2))
        #expect(state.symbolName == "pause.circle")
        #expect(state.variableValue == nil)
        #expect(state.accessibilityStatus == "Queue paused, 2 waiting")
    }

    @Test func aJobFinishingWhilePausedStillShowsItsProgress() {
        #expect(
            StatusIconState(queueCount: 2, runningProgress: 0.9, isPaused: true) == .running(progress: 0.9))
    }

    @Test func waitingJobsOnAnActiveQueueShowAnEmptyRing() {
        #expect(StatusIconState(queueCount: 1, runningProgress: nil, isPaused: false) == .running(progress: 0))
    }

    @Test func buildsFromAnActivitySummary() {
        #expect(StatusIconState(ActivitySummary(jobs: []), isPaused: false) == .idle)
    }

    @Test func mouseButtonEventsPassThroughToTheButton() {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown] {
            #expect(StatusItemHitTest.passesThrough(type))
        }
        // The drag, and no event at all (the drag destination lookup), reach the drop view.
        #expect(!StatusItemHitTest.passesThrough(.leftMouseDragged))
        #expect(!StatusItemHitTest.passesThrough(.mouseMoved))
        #expect(!StatusItemHitTest.passesThrough(nil))
    }
}
