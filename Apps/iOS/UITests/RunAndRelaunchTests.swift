import XCTest

@MainActor
final class RunAndRelaunchTests: AppTestCase {
    /// A queued Photos video converts and lands in Completed, with the original untouched in Photos.
    func testRunToCompleted() throws {
        launch()
        queuePhotosFixture(AppTestCase.secondPhotosFixture)
        waitForCompleted("clip-b")
        open("Videos")
        XCTAssertTrue(
            tile(named: AppTestCase.secondPhotosFixture).waitForExistence(timeout: 15), "the original is gone")
    }

    /// The app is killed while a job is converting. On relaunch the job is back in the queue (not Failed, not lost),
    /// no partial result shows as Completed, and resuming runs it to the end.
    func testKillMidRunThenRelaunchRequeues() throws {
        launch()
        queuePhotosFixture("clip-long.mov")
        open("Queue")
        XCTAssertTrue(runningProgress.waitForExistence(timeout: 180), "the job never started converting")

        app.terminate()
        // Relaunch with the queue paused so the re-queued job can be seen waiting.
        launch(autoStart: false)
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-long").waitForExistence(timeout: 30), "the job was lost")
        XCTAssertFalse(runningProgress.exists, "the job runs after a relaunch with the queue paused")
        open("Completed")
        XCTAssertFalse(
            element(labelContaining: "clip-long").waitForExistence(timeout: 2), "a partial result counts as completed")
        open("Failed")
        XCTAssertFalse(element(labelContaining: "clip-long").waitForExistence(timeout: 2), "the interrupted job failed")

        open("Queue")
        let resume = app.buttons["Resume"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        waitForCompleted("clip-long")
    }
}
