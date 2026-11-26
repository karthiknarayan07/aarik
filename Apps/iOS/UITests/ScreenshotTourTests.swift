import XCTest

/// Saves a screenshot of every main screen as a PNG, for design review. It runs only with `SHOT_DIR` set (pass it as
/// `TEST_RUNNER_SHOT_DIR=<folder>`), so a normal run skips it. Fixture media only, like every other test.
@MainActor
final class ScreenshotTourTests: AppTestCase {
    private static let defaultSize = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    private var shotDirectory: String?

    override func setUp() async throws {
        try await super.setUp()
        shotDirectory = ProcessInfo.processInfo.environment["SHOT_DIR"]
        try XCTSkipIf(shotDirectory == nil, "SHOT_DIR isn't set")
    }

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
        try await super.tearDown()
    }

    private func shot(_ mode: String, _ name: String) {
        guard let shotDirectory else { return }
        let folder = shotDirectory + "/" + mode
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(filePath: "\(folder)/\(name).png"))
    }

    private func ids(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func tour(mode: String, appearance: XCUIDevice.Appearance, contentSize: String) {
        XCUIDevice.shared.appearance = appearance

        // Onboarding, three pages.
        launch(contentSize: contentSize, extraArguments: ["-uiTestingFreshOnboarding"], onboarding: true)
        let next = app.buttons["onboarding.continue"]
        for page in 1...3 {
            XCTAssertTrue(next.waitForExistence(timeout: 10))
            shot(mode, "01-onboarding-\(page)")
            next.tap()
            if page == 2 { sleep(1) }
        }

        // Home, Browse, Convert's pages, with one video queued (paused) so Queue and Home have content.
        launch(autoStart: false, contentSize: contentSize, terminateFirst: true)
        queuePhotosFixture("clip-long.mov")
        open("Home")
        sleep(2)
        shot(mode, "02-home")
        selectTab("Browse", again: true)
        sleep(1)
        shot(mode, "03-browse")
        openConvertHome()
        shot(mode, "04-convert-home")
        open("Photos")
        sleep(2)
        shot(mode, "05-convert-photos")
        app.buttons["selectToggle"].firstMatch.tap()
        let tile = tile(named: AppTestCase.secondPhotosFixture)
        if tile.waitForExistence(timeout: 15) {
            tile.tap()
            _ = ids("convertSelection").waitForExistence(timeout: 10)
            shot(mode, "06-select-bar")
        }
        open("Files")
        sleep(1)
        shot(mode, "07-convert-files")
        open("Queue")
        _ = element(labelContaining: "clip-long").waitForExistence(timeout: 10)
        shot(mode, "08-queue")
        open("Completed")
        sleep(1)
        shot(mode, "09-completed")
        openSettings()
        shot(mode, "12-settings")

        // Ask: the empty state, then a scripted conversation that ends on a confirm card.
        launch(contentSize: contentSize, extraArguments: ["-AssistantDemo"], terminateFirst: true)
        selectTab("Ask")
        XCTAssertTrue(ids("assistant.empty").waitForExistence(timeout: 15))
        shot(mode, "10-ask-empty")
        let field = app.textFields["assistant.composer"]
        field.tap()
        field.typeText("Queue them")
        app.buttons["assistant.send"].tap()
        XCTAssertTrue(ids("assistant.confirmation").waitForExistence(timeout: 20))
        sleep(1)
        shot(mode, "11-ask-conversation")
    }

    func testLight() { tour(mode: "light", appearance: .light, contentSize: Self.defaultSize) }
    func testDark() { tour(mode: "dark", appearance: .dark, contentSize: Self.defaultSize) }
    func testAX3() { tour(mode: "ax3", appearance: .light, contentSize: Self.ax3) }
}
