import Foundation
import Testing

@testable import QuickRunService

@Suite struct EntryPointRoutingTests {
    @Test func launchBufferKeepsEverythingUntilLaunchFinishesThenDeliversOnce() {
        var buffer = LaunchBuffer<URL>()
        let a = URL(filePath: "/tmp/a.mov")
        let b = URL(filePath: "/tmp/b.mov")

        #expect(buffer.receive([a]).isEmpty)
        #expect(buffer.receive([b]).isEmpty)
        #expect(buffer.hasPending)

        #expect(buffer.launchFinished() == [a, b])
        #expect(buffer.launchFinished().isEmpty)
        #expect(!buffer.hasPending)
        // After launch, events pass straight through.
        #expect(buffer.receive([a]) == [a])
    }

    @Test func routeFollowsTheWindow() {
        #expect(OpenedFilesRoute.route(windowVisible: true) == .addToLibrary)
        #expect(OpenedFilesRoute.route(windowVisible: false) == .quickRun)
    }

    @Test func aLaunchWithFilesStaysWindowlessUnlessAResponseNeedsTheWindow() {
        #expect(LaunchWindowPlan.plan(openedFileCount: 0, hasNotificationResponse: false) == .show)
        #expect(LaunchWindowPlan.plan(openedFileCount: 2, hasNotificationResponse: false) == .stayHidden)
        #expect(LaunchWindowPlan.plan(openedFileCount: 2, hasNotificationResponse: true) == .show)
        #expect(LaunchWindowPlan.plan(openedFileCount: 0, hasNotificationResponse: true) == .show)
        // An intent run that started the launch is a quick run too; a notification click still needs the window.
        #expect(
            LaunchWindowPlan.plan(openedFileCount: 0, hasNotificationResponse: false, hasIntentRun: true)
                == .stayHidden)
        #expect(
            LaunchWindowPlan.plan(openedFileCount: 0, hasNotificationResponse: true, hasIntentRun: true) == .show)
    }

    @Test func aWindowIsOnScreenOnlyWhenShownNotMinimizedAndTheAppIsNotHidden() {
        #expect(WindowVisibility.isOnScreen(isWindowVisible: true, isMiniaturized: false, isAppHidden: false))
        #expect(!WindowVisibility.isOnScreen(isWindowVisible: false, isMiniaturized: false, isAppHidden: false))
        #expect(!WindowVisibility.isOnScreen(isWindowVisible: true, isMiniaturized: true, isAppHidden: false))
        #expect(!WindowVisibility.isOnScreen(isWindowVisible: true, isMiniaturized: false, isAppHidden: true))
    }

    @Test func aBannerIsSkippedOnlyWhenTheAppIsActiveAndItsWindowIsOnScreen() {
        #expect(!NotificationPolicy.shouldPost(appIsActive: true, windowOnScreen: true))
        #expect(NotificationPolicy.shouldPost(appIsActive: true, windowOnScreen: false))
        #expect(NotificationPolicy.shouldPost(appIsActive: false, windowOnScreen: true))
        #expect(NotificationPolicy.shouldPost(appIsActive: false, windowOnScreen: false))
    }
}
