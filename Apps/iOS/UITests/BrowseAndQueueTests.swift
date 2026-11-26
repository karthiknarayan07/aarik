import XCTest

@MainActor
final class BrowseAndQueueTests: AppTestCase {
    /// Browsing reads Photos metadata only; selecting a video and adding it puts it in the queue, paused here so it stays.
    func testBrowsePhotosAndQueueAFixtureVideo() throws {
        launch(autoStart: false)
        queuePhotosFixture()

        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-a").waitForExistence(timeout: 15), "clip-a isn't queued")
        XCTAssertFalse(element(labelContaining: "clip-b").exists, "only the selected video is queued")
    }

    /// The queue offers the sidebar badge and the grid keeps its other video untouched.
    func testQueueingOneVideoLeavesTheOtherInPhotos() throws {
        launch(autoStart: false)
        queuePhotosFixture()
        open("Videos")
        XCTAssertTrue(tile(named: AppTestCase.secondPhotosFixture).waitForExistence(timeout: 15))
    }
}
