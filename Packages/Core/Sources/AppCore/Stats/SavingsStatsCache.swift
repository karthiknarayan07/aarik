import Foundation
import Observation

/// What the Overview reads: the last snapshot at once, and a refresh behind it. `load()` only reads the store; a
/// refresh computes a new snapshot, shows it and stores it. A newer request cancels the one still waiting, so a burst
/// of changes makes one refresh, and cancelling the caller (the page going away) cancels the refresh.
@MainActor
@Observable
public final class SavingsStatsCache {
    /// What is shown now: the stored snapshot until a refresh replaces it.
    public private(set) var snapshot: SavingsSnapshot?
    public private(set) var isRefreshing = false
    /// Whether the store has been read, so a page can tell "nothing stored" from "not read yet".
    public private(set) var hasLoaded = false

    @ObservationIgnored private let store: any SavingsStatsStore
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init(store: any SavingsStatsStore) {
        self.store = store
    }

    /// Reads the stored snapshot, unless a refresh has already produced a newer one.
    public func load() async {
        let stored = await store.load()
        if snapshot == nil { snapshot = stored }
        hasLoaded = true
    }

    /// Computes a snapshot after `delay` and stores it.
    public func refresh(
        after delay: Duration = .zero, compute: @escaping @Sendable () async -> SavingsSnapshot
    ) async {
        pending?.cancel()
        let store = store
        let task = Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            isRefreshing = true
            let fresh = await compute()
            guard !Task.isCancelled else {
                isRefreshing = false
                return
            }
            snapshot = fresh
            isRefreshing = false
            await store.save(fresh)
        }
        pending = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancelRefresh() {
        pending?.cancel()
        pending = nil
        isRefreshing = false
    }
}
