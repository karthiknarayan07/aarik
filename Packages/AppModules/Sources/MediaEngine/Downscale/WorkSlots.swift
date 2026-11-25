import Foundation

/// Lets only a few pieces of heavy work run at once. The others wait their turn without holding a thread. Used so
/// that many downscales at once (or, in tests, many encoded fixtures) don't swamp the hardware encoder and slow
/// every one of them down.
public actor WorkSlots {
    /// Half the cores, at least two.
    public static let defaultCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    /// The downscales of this process.
    static let downscales = WorkSlots(count: defaultCount)

    private(set) var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(count: Int) {
        free = count
    }

    var waiting: Int { waiters.count }

    /// Returns once a slot is this caller's; `release()` gives it back.
    public func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the longest waiter, or frees it.
    public func release() {
        if waiters.isEmpty {
            free += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
