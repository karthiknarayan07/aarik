import Foundation

/// Where the last `SavingsSnapshot` is kept. `load` answers from storage without computing anything.
public protocol SavingsStatsStore: Sendable {
    /// The stored snapshot; nil when there is none, or when what is stored can't be read (it is then discarded).
    func load() async -> SavingsSnapshot?
    func save(_ snapshot: SavingsSnapshot) async
    func clear() async
}

/// Keeps the snapshot in memory: for tests, and for a store that couldn't be opened.
public actor InMemorySavingsStatsStore: SavingsStatsStore {
    private var snapshot: SavingsSnapshot?

    public init(_ snapshot: SavingsSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func load() -> SavingsSnapshot? {
        guard let snapshot, snapshot.version == SavingsSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func save(_ snapshot: SavingsSnapshot) { self.snapshot = snapshot }
    public func clear() { snapshot = nil }
}
