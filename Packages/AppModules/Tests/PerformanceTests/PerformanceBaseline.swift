import Darwin
import Foundation

/// What one benchmark measured: the fastest wall-clock time of a run, and the median of how far the process's physical memory
/// footprint rose during a run (peak minus the footprint when the run began).
struct PerformanceSample: Codable, Equatable {
    var seconds: Double
    var peakMemoryMB: Double
}

/// Stored baselines, compared in-test.
///
/// SwiftPM can't keep XCTest's own baselines (`measure` baselines live in an Xcode project or workspace's
/// `xcshareddata`, and `swift test` neither reads nor writes them), so the 20 % guard is this JSON file instead.
/// `XCTClockMetric` and `XCTMemoryMetric` still run, so Xcode and result bundles show them.
///
/// Times and memory depend on the machine, so each baseline belongs to a machine (`MachineKey`). A machine with
/// no baseline is not failed; it measures, prints what it saw, and says how to record one.
struct PerformanceBaselines: Codable, Equatable {
    /// machine key -> benchmark name -> sample.
    var machines: [String: [String: PerformanceSample]] = [:]

    /// A change this much worse than the baseline fails (the plan's 20 %).
    static let tolerance = 0.20

    enum Verdict: Equatable {
        case noBaseline
        case withinTolerance
        /// One sentence per metric that got worse by more than the tolerance.
        case regressed([String])
    }

    static func verdict(measured: PerformanceSample, baseline: PerformanceSample?) -> Verdict {
        guard let baseline else { return .noBaseline }
        var problems: [String] = []
        if measured.seconds > baseline.seconds * (1 + tolerance) {
            problems.append(
                "time \(format(measured.seconds)) s against a baseline of \(format(baseline.seconds)) s "
                    + "(\(percent(measured.seconds, over: baseline.seconds)) worse)")
        }
        if measured.peakMemoryMB > baseline.peakMemoryMB * (1 + tolerance) {
            problems.append(
                "memory \(format(measured.peakMemoryMB)) MB against a baseline of \(format(baseline.peakMemoryMB)) MB "
                    + "(\(percent(measured.peakMemoryMB, over: baseline.peakMemoryMB)) worse)")
        }
        return problems.isEmpty ? .withinTolerance : .regressed(problems)
    }

    func baseline(_ name: String, machine: String) -> PerformanceSample? {
        machines[machine]?[name]
    }

    mutating func record(_ sample: PerformanceSample, as name: String, machine: String) {
        machines[machine, default: [:]][name] = sample
    }

    // MARK: - File

    /// `Baselines/baselines.json` beside this source file (the tests run from the checkout).
    static var fileURL: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Baselines/baselines.json")
    }

    static func load(from url: URL = fileURL) -> PerformanceBaselines {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(PerformanceBaselines.self, from: data)
        else { return PerformanceBaselines() }
        return decoded
    }

    func save(to url: URL = fileURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func percent(_ value: Double, over base: Double) -> String {
        String(format: "%.0f %%", (value / base - 1) * 100)
    }
}

enum MachineKey {
    /// "<hardware model>/<core count>", e.g. "Mac16,1/10".
    static var current: String {
        "\(sysctlString("hw.model") ?? "unknown")/\(ProcessInfo.processInfo.processorCount)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// The physical memory footprint of this process now, in bytes (what `XCTMemoryMetric` and Activity Monitor's
/// "Memory" column report).
func currentFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}
