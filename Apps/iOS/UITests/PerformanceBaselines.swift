import Foundation

/// What one iOS benchmark measured: the fastest wall-clock time of a run, the median peak physical memory of the app
/// during a run, and the median CPU seconds the app used.
struct PerformanceSample: Codable, Equatable {
    var seconds: Double
    var peakMemoryMB: Double
    var cpuSeconds: Double
}

/// Stored baselines, compared in-test, in the same shape and with the same 20 % rule as the Mac's
/// (`Packages/Core/Tests/PerformanceTests`). Xcode's own `measure` baselines belong to a scheme's test plan and are
/// per device; this JSON file (`Baselines/baselines.json`, a resource of the UI test bundle) is what is checked in.
/// `XCTClockMetric`, `XCTMemoryMetric` and `XCTCPUMetric` still run, so the result bundle shows them.
///
/// Each baseline belongs to a machine (`MachineKey`): the Simulator runs on the Mac's CPU, so the key is the
/// simulated device and the host's core count. A machine with no entry measures, prints, and passes.
struct PerformanceBaselines: Codable, Equatable {
    /// machine key -> benchmark name -> sample.
    var machines: [String: [String: PerformanceSample]] = [:]

    static let tolerance = 0.20
    /// Memory and CPU wobble on a machine doing other things, so they get this much room before 20 % counts.
    static let memorySlackMB = 10.0
    static let cpuSlackSeconds = 0.5

    enum Verdict: Equatable {
        case noBaseline
        case withinTolerance
        case regressed([String])
    }

    static func verdict(measured: PerformanceSample, baseline: PerformanceSample?) -> Verdict {
        guard let baseline else { return .noBaseline }
        var problems: [String] = []
        if measured.seconds > baseline.seconds * (1 + tolerance) {
            problems.append(
                "time \(format(measured.seconds)) s against a baseline of \(format(baseline.seconds)) s")
        }
        if measured.peakMemoryMB > baseline.peakMemoryMB * (1 + tolerance) + memorySlackMB {
            problems.append(
                "memory \(format(measured.peakMemoryMB)) MB against a baseline of \(format(baseline.peakMemoryMB)) MB")
        }
        if measured.cpuSeconds > baseline.cpuSeconds * (1 + tolerance) + cpuSlackSeconds {
            problems.append(
                "CPU \(format(measured.cpuSeconds)) s against a baseline of \(format(baseline.cpuSeconds)) s")
        }
        return problems.isEmpty ? .withinTolerance : .regressed(problems)
    }

    func baseline(_ name: String, machine: String) -> PerformanceSample? {
        machines[machine]?[name]
    }

    mutating func record(_ sample: PerformanceSample, as name: String, machine: String) {
        machines[machine, default: [:]][name] = sample
    }

    // MARK: File

    /// The checked-in file, read from the test bundle's resources.
    static func loadBundled() -> PerformanceBaselines {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "baselines", withExtension: "json") else {
            return PerformanceBaselines()
        }
        return load(from: url)
    }

    static func load(from url: URL) -> PerformanceBaselines {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(PerformanceBaselines.self, from: data)
        else { return PerformanceBaselines() }
        return decoded
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private final class BundleToken {}
}

enum MachineKey {
    /// "<simulated device model>/<host core count>", e.g. "iPhone18,3/8".
    static var current: String {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "device"
        return "\(model)/\(ProcessInfo.processInfo.processorCount)"
    }
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}
