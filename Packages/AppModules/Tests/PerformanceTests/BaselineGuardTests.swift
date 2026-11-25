import XCTest

/// The 20 % rule itself. Fast, so these run in every `swift test`.
final class BaselineGuardTests: XCTestCase {
    private let baseline = PerformanceSample(seconds: 2.0, peakMemoryMB: 400)

    func testWithinTwentyPercentPasses() {
        let measured = PerformanceSample(seconds: 2.4, peakMemoryMB: 480)
        XCTAssertEqual(PerformanceBaselines.verdict(measured: measured, baseline: baseline), .withinTolerance)
    }

    func testFasterAndSmallerPasses() {
        let measured = PerformanceSample(seconds: 1.0, peakMemoryMB: 100)
        XCTAssertEqual(PerformanceBaselines.verdict(measured: measured, baseline: baseline), .withinTolerance)
    }

    func testSlowerByMoreThanTwentyPercentFails() {
        let measured = PerformanceSample(seconds: 2.41, peakMemoryMB: 400)
        guard case .regressed(let problems) = PerformanceBaselines.verdict(measured: measured, baseline: baseline)
        else { return XCTFail("expected a regression") }
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("time 2.41 s against a baseline of 2.00 s"), problems[0])
    }

    func testMoreMemoryByMoreThanTwentyPercentFails() {
        let measured = PerformanceSample(seconds: 2.0, peakMemoryMB: 481)
        guard case .regressed(let problems) = PerformanceBaselines.verdict(measured: measured, baseline: baseline)
        else { return XCTFail("expected a regression") }
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("memory 481.00 MB"), problems[0])
    }

    func testBothWorseReportsBoth() {
        let measured = PerformanceSample(seconds: 5, peakMemoryMB: 900)
        guard case .regressed(let problems) = PerformanceBaselines.verdict(measured: measured, baseline: baseline)
        else { return XCTFail("expected a regression") }
        XCTAssertEqual(problems.count, 2)
    }

    func testNoBaselineIsNotAFailure() {
        XCTAssertEqual(PerformanceBaselines.verdict(measured: baseline, baseline: nil), .noBaseline)
    }

    func testBaselinesRoundTripPerMachine() throws {
        var stored = PerformanceBaselines()
        stored.record(baseline, as: "downscale4K", machine: "Mac1,1/8")
        stored.record(PerformanceSample(seconds: 9, peakMemoryMB: 9), as: "downscale4K", machine: "Mac2,2/4")
        let url = FileManager.default.temporaryDirectory.appending(path: "baselines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try stored.save(to: url)
        let loaded = PerformanceBaselines.load(from: url)

        XCTAssertEqual(loaded, stored)
        XCTAssertEqual(loaded.baseline("downscale4K", machine: "Mac1,1/8"), baseline)
        XCTAssertNil(loaded.baseline("downscale4K", machine: "Mac3,3/2"))
        XCTAssertNil(loaded.baseline("other", machine: "Mac1,1/8"))
    }

    func testAMissingOrUnreadableFileMeansNoBaselines() throws {
        XCTAssertEqual(PerformanceBaselines.load(from: URL(filePath: "/nonexistent/baselines.json")).machines.count, 0)
        let url = FileManager.default.temporaryDirectory.appending(path: "bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(PerformanceBaselines.load(from: url).machines.count, 0)
    }

    func testTheMachineKeyNamesTheModelAndCores() {
        let key = MachineKey.current
        XCTAssertTrue(key.contains("/"), key)
        XCTAssertNotEqual(key.split(separator: "/").first, "unknown")
    }
}
