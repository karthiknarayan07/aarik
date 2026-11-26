import XCTest

/// The Simulator's Photos library doesn't behave like an iPhone's (everything is on the device, access is granted).
/// These tests launch the debug stand-in (`UITestPhotoStore`) that does: videos that live in iCloud and download
/// first, and the limited, denied and not-determined access states.
@MainActor
final class PhotosStandInTests: AppTestCase {
    private func ids(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    // MARK: iCloud

    /// A video that is only in iCloud downloads first, and the Queue row and the run status say so with a
    /// percentage, then it converts and completes.
    func testICloudVideoShowsDownloadProgressThenConverts() throws {
        launch(extraArguments: ["-uiTestingICloud", "12"])
        queuePhotosFixture(AppTestCase.secondPhotosFixture, convertNow: true)
        open("Queue")
        let download = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "Downloading from iCloud · [0-9]+%")
        ).firstMatch
        if !download.waitForExistence(timeout: 30) { dump("no download text") }
        XCTAssertTrue(download.exists, "the Queue row never said it was downloading from iCloud")
        LayoutAudit.assertNoOverlaps(in: app)

        // The run status over the tab bar says the same.
        let accessory = ids("jobAccessory")
        XCTAssertTrue(accessory.exists, "no run status over the tab bar")
        XCTAssertTrue(
            accessory.label.contains("Downloading from iCloud"), "the run status says: \(accessory.label)")

        // The percentage moves while the download runs.
        let first = download.label
        let change = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: download)
        wait(for: [change], timeout: 20)

        waitForCompleted("clip-b")
    }

    /// A video in iCloud that was only added to the queue doesn't start downloading.
    func testICloudVideoStaysQueuedUntilStarted() throws {
        launch(extraArguments: ["-uiTestingICloud", "12"])
        queuePhotosFixture(AppTestCase.secondPhotosFixture)
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-b").waitForExistence(timeout: 15))
        XCTAssertFalse(element(labelContaining: "Downloading from iCloud").waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["startQueue"].firstMatch.exists)
    }

    // MARK: Access states

    func testNotDeterminedAsksBeforeShowingAnything() throws {
        launch(extraArguments: ["-uiTestingPhotos", "notDetermined"])
        open("Photos")
        let allow = app.buttons["Allow Access to Photos…"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "no prompt to allow access")
        XCTAssertTrue(element(labelContaining: "See Your Photos Videos").exists)
        XCTAssertFalse(tile(named: AppTestCase.photosFixture).exists, "videos showed before access was given")
        LayoutAudit.assertNoOverlaps(in: app)
        // The person dismisses the system sheet: the prompt stays.
        allow.tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
    }

    func testDeniedShowsHowToTurnAccessOn() throws {
        launch(extraArguments: ["-uiTestingPhotos", "denied"])
        open("Photos")
        XCTAssertTrue(element(labelContaining: "Photos Access Is Off").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Open Settings…"].exists, "no way to open Settings")
        XCTAssertFalse(tile(named: AppTestCase.photosFixture).exists, "videos showed without access")
        LayoutAudit.assertNoOverlaps(in: app)
        open("Home")
        sleep(1)
        LayoutAudit.assertNoOverlaps(in: app)
    }

    func testLimitedShowsTheVideosAndANote() throws {
        launch(extraArguments: ["-uiTestingPhotos", "limited"])
        open("Photos")
        XCTAssertTrue(
            tile(named: AppTestCase.photosFixture).waitForExistence(timeout: 30), "limited access hid the videos")
        XCTAssertTrue(
            element(labelContaining: "Limited access").waitForExistence(timeout: 10), "no note about limited access")
        XCTAssertTrue(app.buttons["Choose More…"].exists)
        LayoutAudit.assertNoOverlaps(in: app)
    }
}
