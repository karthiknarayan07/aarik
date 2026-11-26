#if os(iOS)
    import Convert
    import Foundation
    import Observation

    /// What the Overview draws, kept so it shows at once and refreshes behind it: the totals, the groups and the saved
    /// bytes. It has the shape of Core's `SavingsStatsStore` (a cache, a background refresh and a history), which this
    /// code adopts when that lands; until then `InMemorySavingsStats` stands in.
    struct SavingsStatsSnapshot: Equatable, Sendable {
        struct Group: Equatable, Sendable, Identifiable {
            let id: String
            let title: String
            let couldFree: Int64
        }

        var photos: OverviewSummary.Totals
        var files: OverviewSummary.Totals
        var savedBytes: Int64
        var conversions: Int
        /// The biggest groups first.
        var groups: [Group]

        var couldFree: Int64 { photos.couldFree + files.couldFree }
        var totalBytes: Int64 { photos.bytes + files.bytes }
    }

    /// Bytes freed by the conversions that finished on one day.
    struct SavingsDay: Equatable, Sendable, Identifiable {
        let date: Date
        let savedBytes: Int64
        var id: Date { date }
    }

    @MainActor
    protocol SavingsStatsSource: AnyObject, Observable {
        /// The last totals, or nil before the first refresh.
        var snapshot: SavingsStatsSnapshot? { get }
        var history: [SavingsDay] { get }
        /// Stores a refreshed snapshot and history.
        func store(_ snapshot: SavingsStatsSnapshot, history: [SavingsDay])
    }

    /// The stand-in until the Core store exists: keeps the last numbers in memory for the session.
    @MainActor
    @Observable
    final class InMemorySavingsStats: SavingsStatsSource {
        private(set) var snapshot: SavingsStatsSnapshot?
        private(set) var history: [SavingsDay] = []

        func store(_ snapshot: SavingsStatsSnapshot, history: [SavingsDay]) {
            if self.snapshot != snapshot { self.snapshot = snapshot }
            if self.history != history { self.history = history }
        }
    }
#endif
