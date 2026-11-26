import XCTest

/// Scroll smoothness of Browse ▸ Convert ▸ Photos with a large library: hitch ratio and frame rate while the grid is
/// dragged and while it decelerates.
///
/// Runs only with `RUN_PERF_TESTS=1` (`scripts/ios-ui-tests.sh --perf`). By default the app launches with a synthetic
/// library of 2,500 videos (`-uiTestingFakePhotos`, a Debug-only store; it never touches anyone's Photos). Set
/// `UI_FAKE_PHOTOS=0` to scroll the device's real library instead, which this test only ever reads. The numbers
/// appear in the test log as "Hitch Time Ratio", "Frame Rate" and "Number of Hitches" lines and in the result bundle.
@MainActor
final class PhotosScrollPerformanceTests: AppTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_PERF_TESTS"] == "1", "Set RUN_PERF_TESTS=1 to run the benchmarks")
    }

    private var syntheticCount: Int {
        ProcessInfo.processInfo.environment["UI_FAKE_PHOTOS"].flatMap(Int.init) ?? 2500
    }

    func testPhotosGridScroll() throws {
        let count = syntheticCount
        // The real library is only read. On a device the app can't write into the runner's folders, so it keeps its
        // support files in its own temporary directory.
        if count == 0 { supportDirectory = "@tmp" }
        launch(extraArguments: count > 0 ? ["-uiTestingFakePhotos", String(count)] : [])
        open("Photos")
        let grid = app.scrollViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 60), "The Photos grid didn't appear")
        // Let the first screenful of posters and the library scan settle, so the run measures scrolling only.
        Thread.sleep(forTimeInterval: 3)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let metrics: [XCTMetric] = [
            XCTOSSignpostMetric.scrollDraggingMetric, XCTOSSignpostMetric.scrollDecelerationMetric,
            XCTHitchMetric(application: app), XCTCPUMetric(application: app),
        ]
        measure(metrics: metrics, options: options) {
            for _ in 0..<6 { grid.swipeUp(velocity: .fast) }
            for _ in 0..<6 { grid.swipeDown(velocity: .fast) }
        }
    }
}
