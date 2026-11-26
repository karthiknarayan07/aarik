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
        #expect(!PopoverActivation.shouldActivate(openedBy: .leftMouseUp, voiceOverEnabled: false))
        #expect(!PopoverActivation.shouldActivate(openedBy: .leftMouseDown, voiceOverEnabled: false))
        #expect(!PopoverActivation.shouldActivate(openedBy: .rightMouseDown, voiceOverEnabled: false))
        #expect(PopoverActivation.shouldActivate(openedBy: .keyDown, voiceOverEnabled: false))
        #expect(PopoverActivation.shouldActivate(openedBy: nil, voiceOverEnabled: false))
    }

    @Test func voiceOverAlwaysActivatesThePopoverEvenForAMouseLikePress() {
        #expect(PopoverActivation.shouldActivate(openedBy: .leftMouseUp, voiceOverEnabled: true))
        #expect(PopoverActivation.shouldActivate(openedBy: .leftMouseDown, voiceOverEnabled: true))
        #expect(PopoverActivation.shouldActivate(openedBy: nil, voiceOverEnabled: true))
    }

    @Test func aFileWithNoUsableNameFallsBackToItsContentTypeOnHover() {
        let unnamed = URL(filePath: "/nowhere/IMG_0001")
        #expect(MovieDropFilter.mightContainMovie([unnamed], contentType: { _ in .quickTimeMovie }))
        #expect(!MovieDropFilter.mightContainMovie([unnamed], contentType: { _ in .jpeg }))
        #expect(!MovieDropFilter.mightContainMovie([unnamed], contentType: { _ in nil }))
        // A known extension is decided by the name; the disk isn't asked.
        var asked = 0
        let known = URL(filePath: "/nowhere/a.jpg")
        #expect(
            !MovieDropFilter.mightContainMovie(
                [known],
                contentType: { _ in
                    asked += 1
                    return .movie
                }))
        #expect(asked == 0)
        // A folder is never looked up.
        let folder = URL(filePath: "/nowhere/folder/", directoryHint: .isDirectory)
        #expect(
            !MovieDropFilter.mightContainMovie(
                [folder],
                contentType: { _ in
                    asked += 1
                    return .movie
                }))
        #expect(asked == 0)
    }

    @Test func contentTypeLookupsAreCappedPerDrag() {
        let unnamed = (0..<50).map { URL(filePath: "/nowhere/file\($0)") }
        var asked = 0
        #expect(
            !MovieDropFilter.mightContainMovie(
                unnamed, maxLookups: 5,
                contentType: { _ in
                    asked += 1
                    return nil
                }))
        #expect(asked == 5)
    }

    @Test func partitionSeparatesMoviesFromWhatOnlyLooksLikeOne() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appending(path: "a.mov")
        try Data(count: 16).write(to: movie)
        let missing = folder.appending(path: "gone.mov")
        let text = folder.appending(path: "notes")
        try Data("hello".utf8).write(to: text)
        let directory = folder.appending(path: "clips.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Names alone let the folder and the missing file through; the disk says otherwise.
        #expect(MovieDropFilter.mightContainMovie([missing]))
        let split = MovieDropFilter.partition([missing, movie, text, URL(filePath: directory.path)])
        #expect(split.movies == [movie])
        #expect(split.others.count == 3)
        #expect(!MovieDropFilter.mightContainMovie([text]))
    }

    @Test func systemSettingsLinksPointAtTheRightPanes() {
        #expect(SystemSettingsPane.keyboard?.absoluteString.hasPrefix("x-apple.systempreferences:") == true)
        #expect(
            SystemSettingsPane.notifications(bundleIdentifier: "com.example.app")?.absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.example.app")
        #expect(
            SystemSettingsPane.notifications(bundleIdentifier: nil)?.absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
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
