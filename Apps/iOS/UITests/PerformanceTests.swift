import XCTest

/// iOS performance tests: launch, conversion throughput, and the app's peak memory and CPU during a conversion.
///
/// They run only with `RUN_PERF_TESTS=1` (`scripts/ios-ui-tests.sh --perf` sets it): timings need a quiet machine and
/// would flake in the everyday run. Each benchmark also runs under `measure` with the XCTest metrics, so the result
/// bundle shows them; the pass/fail rule is the 20 % rule against `Baselines/baselines.json` (see PERFORMANCE.md).
/// Record a baseline on a quiet machine with `RECORD_PERF_BASELINE=1` and commit the file.
///
/// The numbers come from the Simulator (software encoder, the Mac's CPU), so they catch regressions between builds,
/// not real-device speed; the on-device check is Instruments on the owner's iPhone (PERFORMANCE.md).
@MainActor
final class PerformanceTests: AppTestCase {
    private var probeURL = URL(filePath: NSTemporaryDirectory()).appending(path: "probe-\(UUID().uuidString).json")

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_PERF_TESTS"] == "1", "Set RUN_PERF_TESTS=1 to run the benchmarks")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: probeURL)
        try await super.tearDown()
    }

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    private struct ProbeReading: Decodable {
        var peakFootprintMB: Double
        var cpuSeconds: Double
    }

    private func readProbe() -> ProbeReading? {
        guard let data = try? Data(contentsOf: probeURL) else { return nil }
        return try? JSONDecoder().decode(ProbeReading.self, from: data)
    }

    private func finish(_ name: String, samples: [PerformanceSample]) throws {
        XCTAssertFalse(samples.isEmpty, "no iteration produced a sample")
        let measured = PerformanceSample(
            seconds: samples.map(\.seconds).min() ?? 0, peakMemoryMB: median(samples.map(\.peakMemoryMB)),
            cpuSeconds: median(samples.map(\.cpuSeconds)))
        let machine = MachineKey.current
        print("PERF \(name) on \(machine): \(measured)")

        let environment = ProcessInfo.processInfo.environment
        if environment["RECORD_PERF_BASELINE"] == "1", let out = environment["UI_BASELINE_OUT"] {
            let url = URL(filePath: out)
            var stored = PerformanceBaselines.load(from: url)
            stored.record(measured, as: name, machine: machine)
            try stored.save(to: url)
            print("PERF recorded \(name) for \(machine) in \(out)")
            return
        }
        switch PerformanceBaselines.verdict(
            measured: measured, baseline: PerformanceBaselines.loadBundled().baseline(name, machine: machine))
        {
        case .noBaseline:
            print("PERF no baseline for \(name) on \(machine); set RECORD_PERF_BASELINE=1 to record one")
        case .withinTolerance: break
        case .regressed(let problems): XCTFail("\(name) regressed: " + problems.joined(separator: "; "))
        }
    }

    /// Time from process launch to the first screen, fastest of the iterations.
    func testLaunch() throws {
        var samples: [PerformanceSample] = []
        measure(metrics: [XCTApplicationLaunchMetric(), XCTClockMetric()], options: options) {
            startMeasuring()
            let start = ContinuousClock.now
            launch(autoStart: false, extraArguments: ["-uiTestingProbe", probeURL.path()])
            let elapsed = start.duration(to: .now)
            stopMeasuring()
            let reading = readProbe()
            samples.append(
                PerformanceSample(
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                    peakMemoryMB: reading?.peakFootprintMB ?? 0, cpuSeconds: reading?.cpuSeconds ?? 0))
        }
        try finish("iosLaunch", samples: samples)
    }

    /// One 4K HLG fixture, from Add to Queue until it shows in Completed, and the app's peak memory and CPU meanwhile.
    func testConversionThroughput() throws {
        var samples: [PerformanceSample] = []
        measure(
            metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app)],
            options: options
        ) {
            launch(extraArguments: ["-uiTestingProbe", probeURL.path()])
            queuePhotosFixture()
            startMeasuring()
            let start = ContinuousClock.now
            waitForCompleted("clip-a", timeout: 300)
            let elapsed = start.duration(to: .now)
            stopMeasuring()
            let reading = readProbe()
            samples.append(
                PerformanceSample(
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                    peakMemoryMB: reading?.peakFootprintMB ?? 0, cpuSeconds: reading?.cpuSeconds ?? 0))
            resetSupportDirectory()
        }
        try finish("iosConversion4K", samples: samples)
    }
}

/// The 20 % rule itself. Fast, and it runs with every UI test run.
final class BaselineGuardTests: XCTestCase {
    private let baseline = PerformanceSample(seconds: 2.0, peakMemoryMB: 400, cpuSeconds: 5)

    func testWithinTwentyPercentPasses() {
        let measured = PerformanceSample(seconds: 2.4, peakMemoryMB: 480, cpuSeconds: 6)
        XCTAssertEqual(PerformanceBaselines.verdict(measured: measured, baseline: baseline), .withinTolerance)
    }

    func testSlowerByMoreThanTwentyPercentFails() {
        let measured = PerformanceSample(seconds: 2.41, peakMemoryMB: 400, cpuSeconds: 5)
        guard case .regressed(let problems) = PerformanceBaselines.verdict(measured: measured, baseline: baseline)
        else { return XCTFail("expected a regression") }
        XCTAssertEqual(problems.count, 1)
    }

    func testMemoryAndCPUWorseReportBoth() {
        let measured = PerformanceSample(seconds: 2.0, peakMemoryMB: 900, cpuSeconds: 20)
        guard case .regressed(let problems) = PerformanceBaselines.verdict(measured: measured, baseline: baseline)
        else { return XCTFail("expected a regression") }
        XCTAssertEqual(problems.count, 2)
    }

    func testNoBaselineIsNotAFailure() {
        XCTAssertEqual(PerformanceBaselines.verdict(measured: baseline, baseline: nil), .noBaseline)
    }

    func testBaselinesRoundTripPerMachine() throws {
        var stored = PerformanceBaselines()
        stored.record(baseline, as: "iosLaunch", machine: "iPhone1,1/8")
        let url = FileManager.default.temporaryDirectory.appending(path: "baselines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try stored.save(to: url)
        let loaded = PerformanceBaselines.load(from: url)
        XCTAssertEqual(loaded, stored)
        XCTAssertNil(loaded.baseline("iosLaunch", machine: "iPhone2,2/8"))
    }

    func testTheCheckedInFileIsReadable() {
        XCTAssertNotNil(
            Bundle(for: BaselineGuardTests.self).url(forResource: "baselines", withExtension: "json"),
            "baselines.json isn't in the UI test bundle")
    }
}
