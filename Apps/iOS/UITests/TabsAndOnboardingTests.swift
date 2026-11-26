import XCTest

/// The app's tab bar (Home, Browse, Ask when Apple Intelligence is there, Search), the Photos-style selection bar, the
/// queue accessory, Search, and the first-launch introduction (which every other test skips with a launch argument).
@MainActor
final class TabsAndOnboardingTests: AppTestCase {
    private func tab(_ title: String) -> XCUIElement {
        tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func testOnboardingShowsOnceAndRemembersItWasSeen() throws {
        launch(extraArguments: ["-uiTestingFreshOnboarding"], onboarding: true)
        if !app.buttons["onboarding.continue"].waitForExistence(timeout: 10) { dump("onboarding") }
        XCTAssertTrue(app.buttons["onboarding.continue"].exists)
        let next = app.buttons["onboarding.continue"]
        for _ in 0..<3 {
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
        }
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "the tab bar didn't show after the introduction")

        launch(terminateFirst: true, onboarding: true)
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.continue"].exists, "the introduction showed a second time")
    }

    func testOnboardingCanBeSkipped() throws {
        launch(extraArguments: ["-uiTestingFreshOnboarding"], onboarding: true)
        let skip = app.buttons["onboarding.skip"]
        if !skip.waitForExistence(timeout: 10) { dump("onboarding skip") }
        XCTAssertTrue(skip.exists)
        skip.tap()
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
    }

    func testTabBarHasHomeBrowseAndSearchAndNoAskWithoutAppleIntelligence() throws {
        launch(autoStart: false, extraArguments: ["-uiTestingAssistant", "unavailable"])
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        for title in ["Home", "Browse", "Search"] {
            XCTAssertTrue(tab(title).waitForExistence(timeout: 10), "No \(title) tab")
        }
        XCTAssertFalse(tab("Ask").exists, "the Ask tab showed without Apple Intelligence")
    }

    func testBrowseShowsToolCardsAndCompletedIsInsideConvert() throws {
        launch(autoStart: false)
        selectTab("Browse")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no tool card in Browse")
        open("Completed")
        XCTAssertTrue(app.navigationBars["Completed"].waitForExistence(timeout: 10))
        XCTAssertFalse(tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Completed'")).firstMatch.exists)
    }

    func testSelectModeShowsTheConvertBarAndQueuesTheSelection() throws {
        launch(autoStart: false)
        open("Photos")
        app.buttons["selectToggle"].firstMatch.tap()
        let tile = tile(named: AppTestCase.photosFixture)
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.tap()
        let convertNow = app.buttons["convertSelection"].firstMatch
        XCTAssertTrue(convertNow.waitForExistence(timeout: 10), "no Convert Now over the selection")
        XCTAssertEqual(convertNow.label, "Convert Now")
        XCTAssertTrue(
            element(labelContaining: "1 Video").exists, "the bar doesn't say what is selected")
        let add = app.buttons["addSelectionToQueue"].firstMatch
        XCTAssertTrue(add.exists, "no Add to Queue over the selection")
        XCTAssertEqual(add.label, "Add to Queue")
        add.tap()
        confirmLossIfAsked()

        // Add to Queue only queues: the job waits, and the tab bar's accessory shows it.
        XCTAssertTrue(
            app.descendants(matching: .any)["jobAccessory"].firstMatch.waitForExistence(timeout: 15),
            "no queue accessory over the tab bar")
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-a").waitForExistence(timeout: 15))
    }

    func testHomeContinuesAWaitingJob() throws {
        launch(autoStart: false)
        queuePhotosFixture()
        open("Home")
        XCTAssertTrue(
            app.descendants(matching: .any)["home.continue"].firstMatch.waitForExistence(timeout: 15),
            "Home shows no Continue for the waiting job")
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
