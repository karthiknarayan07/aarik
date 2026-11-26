import XCTest

@MainActor
final class RunAndRelaunchTests: AppTestCase {
    /// A queued Photos video converts and lands in Completed, with the original untouched in Photos.
    func testRunToCompleted() throws {
        launch()
        queuePhotosFixture(AppTestCase.secondPhotosFixture, convertNow: true)
        waitForCompleted("clip-b")
        open("Photos")
        XCTAssertTrue(
            tile(named: AppTestCase.secondPhotosFixture).waitForExistence(timeout: 15), "the original is gone")
    }

    /// Add to Queue only queues: nothing converts until Start, which then runs the queue to the end.
    func testAddToQueueWaitsForStart() throws {
        launch()
        queuePhotosFixture(AppTestCase.secondPhotosFixture)
        open("Queue")
        let start = app.buttons["startQueue"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the Queue has no Start button")
        XCTAssertTrue(start.label.hasPrefix("Start"), "the button reads \(start.label)")
        XCTAssertFalse(runningProgress.waitForExistence(timeout: 4), "adding to the queue started it")
        start.tap()
        waitForCompleted("clip-b")
    }

    /// The app is killed while a started run is converting. On relaunch the run that was under way continues: the job
    /// is back in the queue (not Failed, not lost), no partial result shows as Completed, and it runs to the end.
    func testKillMidRunThenRelaunchContinuesTheRun() throws {
        launch()
        queuePhotosFixture("clip-long.mov", convertNow: true)
        open("Queue")
        XCTAssertTrue(runningProgress.waitForExistence(timeout: 180), "the job never started converting")

        app.terminate()
        launch(runActive: nil)
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-long").waitForExistence(timeout: 30), "the job was lost")
        open("Completed")
        XCTAssertFalse(
            element(labelContaining: "clip-long").waitForExistence(timeout: 2), "a partial result counts as completed")
        // Completed lists what failed too, so the same check covers an interrupted job that wrongly failed.
        waitForCompleted("clip-long")
    }

    /// A queue that nobody started doesn't start by itself after a relaunch.
    func testQueuedVideoDoesNotStartAfterARelaunch() throws {
        launch()
        queuePhotosFixture("clip-long.mov")
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-long").waitForExistence(timeout: 15))

        app.terminate()
        launch(runActive: nil)
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-long").waitForExistence(timeout: 30), "the job was lost")
        XCTAssertTrue(app.buttons["startQueue"].firstMatch.waitForExistence(timeout: 10), "no Start after a relaunch")
        XCTAssertFalse(runningProgress.waitForExistence(timeout: 4), "the queue started by itself after a relaunch")
    }
}
