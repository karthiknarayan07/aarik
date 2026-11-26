#if DEBUG
    import Darwin
    import Foundation

    /// Debug-only sampler for the iOS performance tests: records this process's peak physical footprint and CPU time
    /// into a small JSON file. The UI test process can't read another process's numbers, so the app reports them.
    /// Started only by the `-uiTestingProbe <file>` launch argument.
    @MainActor
    final class PerformanceProbe {
        static let shared = PerformanceProbe()

        struct Reading: Codable {
            var peakFootprintMB: Double
            var cpuSeconds: Double
        }

        private var task: Task<Void, Never>?

        func start(writingTo url: URL) {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) {
                var peak = 0.0
                while !Task.isCancelled {
                    peak = max(peak, Self.footprintMB())
                    let reading = Reading(peakFootprintMB: peak, cpuSeconds: Self.cpuSeconds())
                    if let data = try? JSONEncoder().encode(reading) { try? data.write(to: url, options: .atomic) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        nonisolated static func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }

        nonisolated static func cpuSeconds() -> Double {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
            func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
            return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }
    }
#endif
