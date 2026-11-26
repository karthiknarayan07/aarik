import XCTest

/// Scroll smoothness of Browse ▸ Convert ▸ Photos with a large library: hitch ratio, frame rate, CPU and memory
/// while the grid is flung up and down for about `UI_SCROLL_SECONDS` (default 20) per iteration.
///
/// Runs only with `RUN_PERF_TESTS=1` (`scripts/ios-ui-tests.sh --perf`, `scripts/device-perf.sh`). By default the app
/// launches with a synthetic library of 2,500 videos (`-uiTestingFakePhotos`, a Debug-only store with mixed sizes and
/// some iCloud-only items; it never touches anyone's Photos). `UI_FAKE_PHOTOS=0` scrolls the device's real library
/// instead, which this test only ever reads. The numbers are in the result bundle and the test log ("Hitch Time
/// Ratio", "Frame Rate", "Number of Hitches"); `scripts/scroll-perf-report.sh` prints them and applies the
/// thresholds in `docs/testing/performance-and-device.md`. The Simulator has no display link, so it reports no
/// hitch or frame-rate data: only a device does.
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

    private var secondsPerIteration: TimeInterval {
        ProcessInfo.processInfo.environment["UI_SCROLL_SECONDS"].flatMap(TimeInterval.init) ?? 20
    }

    /// One fling: a quick drag from low to high (or back) that lets the grid coast.
    private func fling(_ grid: XCUIElement, up: Bool) {
        let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.78 : 0.3))
        let to = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.78))
        from.press(forDuration: 0.02, thenDragTo: to, withVelocity: 2500, thenHoldForDuration: 0)
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
        let library = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' videos'")).allElementsBoundByIndex
        print("PERF library: \(library.map(\.label))")

        // The flings must move the grid, or a short library would measure nothing.
        func tileFrames() -> [String] {
            grid.buttons.allElementsBoundByIndex.map { "\($0.label)@\(Int($0.frame.minY))" }
        }
        let before = tileFrames()
        for _ in 0..<3 { fling(grid, up: true) }
        XCTAssertNotEqual(before, tileFrames(), "The grid didn't scroll; its library may be too small to measure")
        for _ in 0..<3 { fling(grid, up: false) }

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        let metrics: [XCTMetric] = [
            XCTOSSignpostMetric.scrollDraggingMetric, XCTOSSignpostMetric.scrollDecelerationMetric,
            XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
        ]
        let seconds = secondsPerIteration
        measure(metrics: metrics, options: options) {
            let end = Date().addingTimeInterval(seconds)
            var up = true
            while Date() < end {
                for _ in 0..<4 { fling(grid, up: up) }
                up.toggle()
            }
        }
    }
}
