import CoreMedia

/// Drops frames so the kept ones are at most `maxFrameRate` per second, tolerant of timestamp jitter.
struct FrameRateLimiter {
    private let interval: Double?
    private var nextAllowed = -Double.infinity

    init(maxFrameRate: Double?) {
        interval = maxFrameRate.flatMap { $0 > 0 ? 1 / $0 : nil }
    }

    /// Keeps a frame iff `pts >= nextAllowed`. On keep,
    /// `nextAllowed = max(nextAllowed + 1/max, pts + 1/max − tolerance)` with tolerance = 1/(4·max).
    mutating func shouldKeep(presentationTime: CMTime) -> Bool {
        guard let interval else { return true }
        let pts = presentationTime.seconds
        guard pts >= nextAllowed else { return false }
        nextAllowed = max(nextAllowed + interval, pts + interval - interval / 4)
        return true
    }
}
