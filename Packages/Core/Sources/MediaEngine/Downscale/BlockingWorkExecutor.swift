import Dispatch

/// Runs one downscale's work on its own serial queue instead of Swift's shared cooperative pool. A downscale waits
/// for decoded frames with blocking reads (`copyNextSampleBuffer`); on the pool, enough downscales at once block
/// every pool thread while the work they wait for needs one, and none finishes.
final class BlockingWorkExecutor: TaskExecutor {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .unspecified) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
