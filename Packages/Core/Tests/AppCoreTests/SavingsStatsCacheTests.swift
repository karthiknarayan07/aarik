import Foundation
import Testing

@testable import AppCore

/// The savings cache: it answers from storage at once, a refresh replaces and stores what it shows, and a store that
/// can't be read starts over instead of failing.
@MainActor
@Suite(.serialized) struct SavingsStatsCacheTests {
    nonisolated private static let day = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated private static func snapshot(saved: Int64) -> SavingsSnapshot {
        SavingsSnapshot(
            updatedAt: day,
            libraries: [.init(name: "Local Files", count: 3, bytes: 9_000, couldFree: 4_000)],
            groups: [.init(id: "B1", title: "4K from 2026", bytes: 4_000)],
            days: [.init(day: day, videos: 2, savedBytes: saved)], savedBytes: saved, conversions: 2)
    }

    private static func directory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "savings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func loadShowsTheStoredSnapshotWithoutComputing() async {
        let stored = Self.snapshot(saved: 700)
        let cache = SavingsStatsCache(store: InMemorySavingsStatsStore(stored))
        #expect(cache.snapshot == nil)
        await cache.load()
        #expect(cache.snapshot == stored)
        #expect(cache.hasLoaded)
        #expect(!cache.isRefreshing)
    }

    @Test func refreshReplacesTheSnapshotAndStoresIt() async {
        let store = InMemorySavingsStatsStore(Self.snapshot(saved: 700))
        let cache = SavingsStatsCache(store: store)
        await cache.load()
        await cache.refresh { Self.snapshot(saved: 900) }
        #expect(cache.snapshot?.savedBytes == 900)
        #expect(await store.load()?.savedBytes == 900)
    }

    @Test func aNewerRefreshReplacesOneStillWaiting() async {
        let cache = SavingsStatsCache(store: InMemorySavingsStatsStore())
        async let first: Void = cache.refresh(after: .seconds(30)) { Self.snapshot(saved: 1) }
        await Task.yield()
        await cache.refresh { Self.snapshot(saved: 2) }
        await first
        #expect(cache.snapshot?.savedBytes == 2)
    }

    @Test func cancellingTheCallerCancelsTheRefresh() async {
        let store = InMemorySavingsStatsStore()
        let cache = SavingsStatsCache(store: store)
        let task = Task { await cache.refresh(after: .seconds(30)) { Self.snapshot(saved: 5) } }
        await Task.yield()
        task.cancel()
        await task.value
        #expect(cache.snapshot == nil)
        #expect(await store.load() == nil)
    }

    @Test func aSnapshotOfAnotherVersionIsNotRead() async {
        var old = Self.snapshot(saved: 1)
        old.version = SavingsSnapshot.currentVersion + 1
        let cache = SavingsStatsCache(store: InMemorySavingsStatsStore(old))
        await cache.load()
        #expect(cache.snapshot == nil)
    }

    @Test func swiftDataStoreKeepsTheSnapshotAndHistoryBetweenOpenings() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = Self.snapshot(saved: 700)
        await SwiftDataSavingsStatsStore(directory: directory).save(snapshot)
        let reopened = await SwiftDataSavingsStatsStore(directory: directory).load()
        #expect(reopened == snapshot)
        // A second save replaces, it doesn't add.
        let store = SwiftDataSavingsStatsStore(directory: directory)
        await store.save(Self.snapshot(saved: 800))
        #expect(await store.load()?.days.count == 1)
        #expect(await store.load()?.savedBytes == 800)
    }

    // MARK: Nothing saved yet

    /// A new install: no groups, every number zero. The Overview's charts get a zero-length axis from it.
    nonisolated private static var empty: SavingsSnapshot {
        SavingsSnapshot(
            updatedAt: day, libraries: [.init(name: "Local Files", count: 0, bytes: 0, couldFree: 0)], groups: [],
            days: [.init(day: day, videos: 0, savedBytes: 0)], savedBytes: 0, conversions: 0)
    }

    @Test func anAllZeroSnapshotIsShownStoredAndReadBack() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SavingsStatsCache(store: SwiftDataSavingsStatsStore(directory: directory))
        await cache.refresh { Self.empty }
        #expect(cache.snapshot == Self.empty)
        #expect(!cache.isRefreshing)

        let reopened = SavingsStatsCache(store: SwiftDataSavingsStatsStore(directory: directory))
        await reopened.load()
        #expect(reopened.snapshot == Self.empty)
        #expect(reopened.hasLoaded)
    }

    @Test func aStoredSnapshotWithNoRowsIsNotMistakenForNothingStored() async {
        var bare = Self.empty
        bare.libraries = []
        bare.days = []
        let cache = SavingsStatsCache(store: InMemorySavingsStatsStore(bare))
        await cache.load()
        #expect(cache.snapshot == bare)
        #expect(cache.snapshot?.days.isEmpty == true)
    }

    @Test func aZeroRefreshReplacesLargerNumbers() async {
        let cache = SavingsStatsCache(store: InMemorySavingsStatsStore(Self.snapshot(saved: 700)))
        await cache.load()
        await cache.refresh { Self.empty }
        #expect(cache.snapshot?.savedBytes == 0)
        #expect(cache.snapshot?.days.map(\.savedBytes) == [0])
    }

    @Test func aChartAxisNeverHasZeroLength() {
        let zeros: [Int64] = [0, 0, 0]
        #expect(ChartCeiling.of(zeros) == 1)
        #expect(ChartCeiling.of([Int64]()) == 1)
        #expect(ChartCeiling.of([Int]()) == 1)
        #expect(ChartCeiling.of(Self.empty.days.map(\.savedBytes)) == 1)
        #expect(ChartCeiling.of(Self.empty.groups.map(\.bytes)) == 1)
        #expect(ChartCeiling.of([5, 0, 9] as [Int64]) == 9)
        #expect(ChartCeiling.of(Self.snapshot(saved: 700).days.map(\.savedBytes)) == 700)
    }

    @Test func aDamagedStoreRecoversAsAnEmptyCache() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: SwiftDataSavingsStatsStore.fileName)
        try Data("not a database".utf8).write(to: file)
        let jobs = directory.appending(path: "jobs.json")
        try Data("[]".utf8).write(to: jobs)

        let store = SwiftDataSavingsStatsStore(directory: directory)
        #expect(await store.load() == nil)
        await store.save(Self.snapshot(saved: 3))
        #expect(await store.load()?.savedBytes == 3)
        // Only the cache is rebuilt; the other stores are left as they were.
        #expect(try Data(contentsOf: jobs) == Data("[]".utf8))
    }
}
