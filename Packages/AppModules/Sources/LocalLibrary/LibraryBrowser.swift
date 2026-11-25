import Foundation
import Observation

/// What the grid shows: the library filtered by media type, name and quality, grouped and sorted, plus the
/// selection.
///
/// The snapshot and anything derived from it (`cached`) are rebuilt only when the items or the query change; the
/// query includes the quality filter, so totals and savings follow it. A selection change never rebuilds them.
@MainActor
@Observable
public final class LibraryBrowser {
    /// The visible items, computed once per change of items or query.
    public struct Snapshot: Sendable {
        public let groups: [ItemGroup]
        public let items: [LibraryItem]
        public let totalBytes: Int64
        /// The quality options present among the items the media-type filter and search let through, with counts.
        public let facets: QualityFacets
        /// Grid order of each visible item.
        let positions: [UUID: Int]

        init(groups: [ItemGroup], facets: QualityFacets = .empty) {
            self.groups = groups
            self.facets = facets
            self.items = groups.flatMap(\.items)
            self.totalBytes = items.reduce(0) { $0 + $1.byteSize }
            self.positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        }
    }

    public var grouping: Grouping = .month
    public var sort: Sort = .biggestFirst
    public var filter: MediaBadge?
    public var search = ""
    /// Resolution and frame rate, size, length, codec and dynamic range; combined with `filter` and `search`.
    public var quality = QualityFilter()
    /// The grid's selection. A search can hide some of it; `selectedItems` leaves those out.
    public var selection: Set<UUID> = []

    public let library: LocalLibrary

    /// Test seams: how often the snapshot and derived values were rebuilt.
    @ObservationIgnored public private(set) var snapshotBuilds = 0
    @ObservationIgnored public private(set) var derivedBuilds = 0

    private struct Query: Equatable {
        let revision: Int
        let grouping: Grouping
        let sort: Sort
        let filter: MediaBadge?
        let search: String
        let quality: QualityFilter
    }

    @ObservationIgnored private var query: Query?
    @ObservationIgnored private var current = Snapshot(groups: [])
    @ObservationIgnored private var derived: [AnyHashable: Any] = [:]

    public init(library: LocalLibrary) {
        self.library = library
    }

    public var snapshot: Snapshot {
        let next = Query(
            revision: library.revision, grouping: grouping, sort: sort, filter: filter,
            search: search.trimmingCharacters(in: .whitespacesAndNewlines), quality: quality)
        if next != query {
            query = next
            current = Self.snapshot(library.items, query: next)
            derived.removeAll()
            snapshotBuilds += 1
        }
        return current
    }

    /// A value computed from the snapshot, kept until the snapshot or `key` changes.
    public func cached<Value>(_ key: some Hashable, _ compute: (Snapshot) -> Value) -> Value {
        let snapshot = self.snapshot
        if let value = derived[AnyHashable(key)] as? Value { return value }
        let value = compute(snapshot)
        derived[AnyHashable(key)] = value
        derivedBuilds += 1
        return value
    }

    /// Selected items that are visible, in grid order. Hidden items are never included.
    public var selectedItems: [LibraryItem] {
        let snapshot = self.snapshot
        return selection.compactMap { snapshot.positions[$0] }.sorted().map { snapshot.items[$0] }
    }

    /// Media type and search narrow the collection; the quality filter then picks from it and counts its options
    /// there, so the bar offers only what the current collection has.
    private static func snapshot(_ items: [LibraryItem], query: Query) -> Snapshot {
        let collection = items.filter { item in
            (query.filter.map(item.badges.contains) ?? true)
                && (query.search.isEmpty || item.url.lastPathComponent.localizedStandardContains(query.search))
        }
        let (kept, facets) = query.quality.apply(to: collection)
        let groups = LibraryGrouper.groups(kept, by: query.grouping, sort: query.sort, filter: nil)
        return Snapshot(groups: groups, facets: facets)
    }
}
