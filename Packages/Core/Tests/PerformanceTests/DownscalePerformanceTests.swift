import Foundation
import MediaEngine
import MediaTestSupport
import Synchronization
import XCTest

/// Times and memory of a 4K to 1080p downscale on a generated clip (no personal media is ever used).
///
/// Off unless `RUN_PERF_TESTS=1`: a stable timing needs a quiet machine and several encodes, so it doesn't belong in
/// the everyday run. The CI job `performance` sets it. `RECORD_PERF_BASELINE=1` writes this machine's numbers into
/// `Baselines/baselines.json` instead of comparing (do it on a quiet Mac, in a Release-like state, and commit the
/// file). Without a baseline for the machine the test measures and passes, saying what it saw.
final class DownscalePerformanceTests: XCTestCase {
    private static let benchmark = "downscale4K"
    private static let iterations = 5

    private var enabled: Bool { ProcessInfo.processInfo.environment["RUN_PERF_TESTS"] == "1" }
    private var recording: Bool { ProcessInfo.processInfo.environment["RECORD_PERF_BASELINE"] == "1" }

    /// 3840x2160 HLG HEVC at 30 fps, two seconds, at a phone-like bit rate, with audio.
    private func makeSource() throws -> URL {
        try Self.blocking {
            var options = ClipOptions()
            options.width = 3840
            options.height = 2160
            options.fps = 30
            options.seconds = 2
            options.videoBitRate = 40_000_000
            return try await FixtureFactory.makeClip(options)
        }
    }

    func testDownscale4KTo1080ClockAndMemory() throws {
        try XCTSkipUnless(enabled, "Set RUN_PERF_TESTS=1 to run the performance tests")
        let source = try makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = DownscaleSpec(targetShortSide: 1080, averageBitRate: 12_000_000)

        // What each run of the block saw. The time kept is the fastest run: load from other work on the machine only
        // ever adds to a run, while a real slowdown moves every run.
        // `measure` also feeds XCTClockMetric and XCTMemoryMetric.
        let runs = RunLog()
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let output = directory.appending(path: "output-\(UUID().uuidString).mov")
            let sampler = FootprintSampler()
            let started = ContinuousClock.now
            do {
                try Self.blocking {
                    try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { _ in }
                }
            } catch {
                XCTFail("downscale failed: \(error)")
            }
            let elapsed = started.duration(to: .now)
            let rise = sampler.stop()
            try? FileManager.default.removeItem(at: output)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            runs.add(PerformanceSample(seconds: seconds, peakMemoryMB: Double(rise) / 1_000_000))
        }

        let all = runs.all
        XCTAssertGreaterThanOrEqual(all.count, Self.iterations)
        let measured = PerformanceSample(
            seconds: all.map(\.seconds).min() ?? 0, peakMemoryMB: Self.median(all.map(\.peakMemoryMB)))
        try judge(measured)
    }

    private func judge(_ measured: PerformanceSample) throws {
        let machine = MachineKey.current
        var stored = PerformanceBaselines.load()
        let summary =
            "\(Self.benchmark) on \(machine): \(String(format: "%.2f", measured.seconds)) s, "
            + "\(String(format: "%.0f", measured.peakMemoryMB)) MB"

        // `PERF_REPORT_PATH`: also write what was measured as JSON, for CI to upload.
        if let path = ProcessInfo.processInfo.environment["PERF_REPORT_PATH"] {
            var report = PerformanceBaselines()
            report.record(measured, as: Self.benchmark, machine: machine)
            try report.save(to: URL(filePath: path))
        }

        if recording {
            stored.record(measured, as: Self.benchmark, machine: machine)
            try stored.save()
            print("Recorded baseline: \(summary)")
            return
        }
        switch PerformanceBaselines.verdict(
            measured: measured, baseline: stored.baseline(Self.benchmark, machine: machine))
        {
        case .noBaseline:
            print(
                "No baseline for \(machine), so nothing to compare: \(summary). "
                    + "Record one with RECORD_PERF_BASELINE=1.")
        case .withinTolerance:
            print("Within 20 % of the baseline: \(summary)")
        case .regressed(let problems):
            XCTFail("\(Self.benchmark) regressed by more than 20 %: " + problems.joined(separator: "; "))
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Runs async work to completion from a synchronous test or `measure` block.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = Mutex<Result<T, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result = await Task { try await work() }.result
            outcome.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return try outcome.withLock { $0 }!.get()
    }
}

final class RunLog: Sendable {
    private let samples = Mutex<[PerformanceSample]>([])

    func add(_ sample: PerformanceSample) { samples.withLock { $0.append(sample) } }
    var all: [PerformanceSample] { samples.withLock { $0 } }
}

/// Polls the process's memory footprint while something runs, and reports how far above its starting value it got.
final class FootprintSampler: Sendable {
    private let state = Mutex((start: Int64(0), peak: Int64(0), running: true))

    init() {
        let start = currentFootprint()
        state.withLock { $0 = (start, start, true) }
        let thread = Thread { [self] in
            while state.withLock({ $0.running }) {
                let now = currentFootprint()
                state.withLock { $0.peak = max($0.peak, now) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops sampling. Returns peak minus start, in bytes (never negative).
    func stop() -> Int64 {
        let now = currentFootprint()
        return state.withLock {
            $0.running = false
            $0.peak = max($0.peak, now)
            return max(0, $0.peak - $0.start)
        }
    }
}
