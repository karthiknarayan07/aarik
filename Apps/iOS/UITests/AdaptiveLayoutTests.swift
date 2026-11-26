import XCTest

/// Review Focus 1: a size-class or posture change (iPhone rotation here, iPad rotation on the iPad, the Duo's default
/// posture) keeps the selection, the open sheet and the running job: no reload, no restarted job.
///
/// XCUITest can rotate a device but cannot fold a Duo or enter iPad split view; those are checked by hand
/// (docs/RELEASING.md, "Adaptive layout").
@MainActor
final class AdaptiveLayoutTests: AppTestCase {
    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private func percent(in label: String) -> Int? {
        guard let range = label.range(of: #"\d+(?=%)"#, options: .regularExpression) else { return nil }
        return Int(label[range])
    }

    func testSelectionSurvivesRotation() throws {
        launch(autoStart: false)
        open("Videos")
        let tile = tile(named: AppTestCase.photosFixture)
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.tap()
        XCTAssertTrue(tile.isSelected, "the tile didn't select")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(self.tile(named: AppTestCase.photosFixture).waitForExistence(timeout: 10))
        XCTAssertTrue(self.tile(named: AppTestCase.photosFixture).isSelected, "rotation dropped the selection")
        XCTAssertTrue(app.buttons["Add to Queue"].firstMatch.isEnabled, "rotation disabled Add to Queue")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(self.tile(named: AppTestCase.photosFixture).waitForExistence(timeout: 10))
        XCTAssertTrue(self.tile(named: AppTestCase.photosFixture).isSelected, "rotating back dropped the selection")
    }

    func testOpenSheetSurvivesRotation() throws {
        launch(autoStart: false)
        openSettings()

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "rotation closed the sheet")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "rotating back closed the sheet")
    }

    func testRunningJobKeepsRunningThroughRotation() throws {
        launch()
        queuePhotosFixture()
        open("Queue")
        XCTAssertTrue(runningProgress.waitForExistence(timeout: 180), "the job never started converting")
        let before = percent(in: runningProgress.label) ?? 0

        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait

        // A restarted job would start again from 0 %; it either still runs from where it was or already finished.
        if runningProgress.waitForExistence(timeout: 3) {
            XCTAssertGreaterThanOrEqual(
                (percent(in: runningProgress.label) ?? 100) + 2, before, "the job restarted")
        }
        waitForCompleted("clip-a")
    }
}
