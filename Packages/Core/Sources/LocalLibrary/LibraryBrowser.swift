import Foundation
import Observation

/// Which kind of media items are visible in the browser.
public enum MediaKindFilter: String, CaseIterable, Sendable, Hashable, Identifiable {
    case all, videos, images

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: "All"
        case .videos: "Videos"
        case .images: "Images"
        }
    }

    public func matches(_ item: LibraryItem) -> Bool {
        switch self {
        case .all: true
        case .videos: item.isVideo
        case .images: item.isImage
        }
    }
}

/// What the grid shows: the library filtered by media kind, badge, name and quality, grouped and sorted, plus the
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

    public var mediaFilter: MediaKindFilter = .all
    public var grouping: Grouping = .month
    public var sort: Sort = .biggestFirst
    public var filter: MediaBadge?
    public var search = ""
    /// Resolution and frame rate, size, length, codec and dynamic range; combined with `filter` and `search`.
    public var quality = QualityFilter()
    /// Only items captured inside this range; items with no capture date are hidden while it is set.
    public var captureRange: ClosedRange<Date>?
    /// Items to hide, for example the ones already shrunk.
    public var excluded: Set<UUID> = []
    /// The grid's selection. A search can hide some of it; `selectedItems` leaves those out.
    public var selection: Set<UUID> = []

    public let collection: any MediaCollection

    /// Test seams: how often the snapshot and derived values were rebuilt.
    @ObservationIgnored public private(set) var snapshotBuilds = 0
    @ObservationIgnored public private(set) var derivedBuilds = 0

    private struct Query: Equatable {
        let revision: Int
        let mediaFilter: MediaKindFilter
        let grouping: Grouping
        let sort: Sort
        let filter: MediaBadge?
        let search: String
        let quality: QualityFilter
        let captureRange: ClosedRange<Date>?
        let excluded: Set<UUID>
    }

    @ObservationIgnored private var query: Query?
    @ObservationIgnored private var current = Snapshot(groups: [])
    @ObservationIgnored private var derived: [AnyHashable: Any] = [:]

    public init(collection: any MediaCollection) {
        self.collection = collection
    }

    public var snapshot: Snapshot {
        let next = Query(
            revision: collection.revision, mediaFilter: mediaFilter, grouping: grouping, sort: sort, filter: filter,
            search: search.trimmingCharacters(in: .whitespacesAndNewlines), quality: quality,
            captureRange: captureRange, excluded: excluded)
        if next != query {
            query = next
            current = Self.snapshot(collection.items, query: next)
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
            query.mediaFilter.matches(item)
                && (query.filter.map(item.badges.contains) ?? true)
                && (query.search.isEmpty || item.name.localizedStandardContains(query.search))
                && !query.excluded.contains(item.id)
                && (query.captureRange.map { range in item.captureDate.map(range.contains) ?? false } ?? true)
        }
        let (kept, facets) = query.quality.apply(to: collection)
        let groups = LibraryGrouper.groups(kept, by: query.grouping, sort: query.sort, filter: nil)
        return Snapshot(groups: groups, facets: facets)
    }
}
