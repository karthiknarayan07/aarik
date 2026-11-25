import Foundation

/// Lets only a few pieces of heavy work run at once. The others wait their turn without holding a thread. Used so
/// that many downscales at once (or, in tests, many encoded fixtures) don't swamp the hardware encoder and slow
/// every one of them down.
///
/// The limit can change at any time (`setLimit`). Raising it admits waiters at once; lowering it never stops work that
/// is running, it only holds back new work until enough of it has finished.
public actor WorkSlots {
    /// Half the cores, at least two.
    public static let defaultCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    /// The downscales of this process.
    static let downscales = WorkSlots(count: defaultCount)

    private(set) var limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(count: Int) {
        limit = max(1, count)
    }

    var waiting: Int { waiters.count }

    /// Slots nobody holds; zero while more work runs than the limit allows.
    var free: Int { max(0, limit - inUse) }

    /// Returns once a slot is this caller's; `release()` gives it back.
    public func acquire() async {
        if inUse < limit, waiters.isEmpty {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the longest waiter, or frees it.
    public func release() {
        inUse -= 1
        admitWaiters()
    }

    /// Changes how many may run at once (at least one). Work already running is never stopped.
    public func setLimit(_ count: Int) {
        limit = max(1, count)
        admitWaiters()
    }

    private func admitWaiters() {
        while inUse < limit, !waiters.isEmpty {
            inUse += 1
            waiters.removeFirst().resume()
        }
    }
}
