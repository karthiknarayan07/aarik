import XCTest

/// Cold-launch time with `XCTApplicationLaunchMetric`, in the Mac UI test target (`UITests`).
///
/// Baselines: an Xcode project keeps XCTest baselines (the metric's "Set Baseline" in the Report navigator, stored
/// in the project's `xcshareddata/xcbaselines`), and a run fails when it is worse than the baseline set for this Mac by
/// more than the metric's "Max % Regression". Xcode's default for that is 10 %: set it to 20 when setting the
/// baseline, to match the plan's 20 % rule. The budget is a cold launch under 1 s in a **Release** build (`PERFORMANCE.md`); a Debug build
/// is slower and tells nothing, so set the baseline from a Release run:
///
///     RUN_PERF_TESTS=1 xcodebuild test -workspace App.xcworkspace -scheme App -configuration Release \
///       -only-testing:UITests/LaunchPerformanceTests
///
/// Skipped unless `RUN_PERF_TESTS=1`, like the package's performance tests: it launches the app several times and
/// needs the Mac's automation permission.
@MainActor
final class LaunchPerformanceTests: UITestCase {
    func testColdLaunch() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_PERF_TESTS"] == "1",
            "Set RUN_PERF_TESTS=1 to run the performance tests")
        app.launchArguments = [
            "-uiTesting", root.path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)",
        ]

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
            app.terminate()
        }
    }
}
