import XCTest

/// The tool's floating tab bar, the Photos-style selection bar, the queue accessory, Search, and the first-launch
/// introduction (which every other test skips with a launch argument).
@MainActor
final class TabsAndOnboardingTests: AppTestCase {
    func testOnboardingShowsOnceAndRemembersItWasSeen() throws {
        launch(onboarding: true)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding"].firstMatch.waitForExistence(timeout: 10))
        let next = app.buttons["onboarding.continue"]
        for _ in 0..<3 {
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
        }
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool.'")).firstMatch
                .waitForExistence(timeout: 10), "the Tools list didn't show after the introduction")

        launch(terminateFirst: true, onboarding: true)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool.'")).firstMatch
                .waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.continue"].exists, "the introduction showed a second time")
    }

    func testOnboardingCanBeSkipped() throws {
        launch(onboarding: true)
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool.'")).firstMatch
                .waitForExistence(timeout: 10))
    }

    func testTabBarHasOverviewLibraryQueueAndSearch() throws {
        launch(autoStart: false)
        revealTabs()
        for title in ["Overview", "Library", "Queue", "Search"] {
            XCTAssertTrue(
                tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
                    .waitForExistence(timeout: 10), "No \(title) tab")
        }
        // Completed sits inside Queue.
        open("Completed")
        XCTAssertTrue(app.segmentedControls.buttons["Queue"].exists)
    }

    func testSelectModeShowsTheConvertBarAndQueuesTheSelection() throws {
        launch(autoStart: false)
        open("Photos")
        app.buttons["selectToggle"].firstMatch.tap()
        let tile = tile(named: AppTestCase.photosFixture)
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.tap()
        let bar = app.buttons["convertSelection"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no Convert bar over the selection")
        XCTAssertTrue(bar.label.hasPrefix("Convert 1 Video"), "the bar reads \(bar.label)")
        bar.tap()
        confirmLossIfAsked()

        // The job waits (auto-start is off), and the tab bar's accessory shows it.
        XCTAssertTrue(
            app.descendants(matching: .any)["jobAccessory"].firstMatch.waitForExistence(timeout: 15),
            "no queue accessory over the tab bar")
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-a").waitForExistence(timeout: 15))
    }

    func testSearchFindsAVideoAndOpensIt() throws {
        launch(autoStart: false)
        selectTab("Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("clip-a")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'clip-a'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "Search found no clip-a")
        result.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["videoDetail"].firstMatch.waitForExistence(timeout: 15),
            "the result didn't open the video's page")
    }
}
