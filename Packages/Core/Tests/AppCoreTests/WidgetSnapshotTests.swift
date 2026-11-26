import Foundation
import Testing

@testable import AppCore

@Suite("Widget snapshot store")
struct WidgetSnapshotTests {
    private final class BundleToken {}

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func bundleWithoutAppGroupReturnsNilIdentifierAndNilStore() {
        let bundle = Bundle(for: BundleToken.self)
        #expect(AppGroup.identifier(in: bundle) == nil)
        #expect(AppGroup.pauseNotificationName(in: bundle) == nil)
        #expect(WidgetSnapshotStore(bundle: bundle) == nil)
    }

    @Test func emptyStoreReturnsNilOnLoadAndZeroesOnLoadOrEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = WidgetSnapshotStore(directory: dir)
        #expect(store.load() == nil)
        let fallback = store.loadOrEmpty()
        #expect(fallback.savedBytes == 0)
        #expect(fallback.queueCount == 0)
        #expect(fallback.completedCount == 0)
        #expect(fallback.isPaused == false)
    }

    @Test func saveCreatesDirectoryAndRoundTripsSnapshot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("group-container", isDirectory: true)
        let store = WidgetSnapshotStore(directory: nested)
        let timestamp = Date(timeIntervalSince1970: 1_764_000_000)
        let snapshot = WidgetSnapshot(
            savedBytes: 2_400_000_000,
            queueCount: 4,
            completedCount: 12,
            isPaused: true,
            updatedAt: timestamp
        )

        try store.save(snapshot)
        let loaded = try #require(store.load())
        #expect(loaded == snapshot)
    }

    @Test func activitySummaryMapsCleanlyToSnapshot() {
        let outcome = JobOutcome(
            output: URL(filePath: "/tmp/out.mov"),
            bytesBefore: 1_000_000,
            bytesAfter: 400_000,
            report: MetadataReport(),
            replacedOriginal: false
        )
        let jobs = [
            Job(
                toolID: "convert", source: URL(filePath: "/tmp/a.mov"), sourceBookmark: Data(), settings: Data(),
                state: .queued),
            Job(
                toolID: "convert", source: URL(filePath: "/tmp/b.mov"), sourceBookmark: Data(), settings: Data(),
                state: .running(progress: 0.5)),
            Job(
                toolID: "convert", source: URL(filePath: "/tmp/c.mov"), sourceBookmark: Data(), settings: Data(),
                state: .completed(outcome)),
        ]
        let summary = ActivitySummary(jobs: jobs)
        let snapshot = WidgetSnapshot(activity: summary, isPaused: true)

        #expect(snapshot.savedBytes == 600_000)
        #expect(snapshot.queueCount == 2)
        #expect(snapshot.completedCount == 1)
        #expect(snapshot.isPaused == true)
    }

    @Test func negativeValuesClampToZeroOnInitAndDecode() throws {
        let clamped = WidgetSnapshot(savedBytes: -50, queueCount: -3, completedCount: -1)
        #expect(clamped.savedBytes == 0)
        #expect(clamped.queueCount == 0)
        #expect(clamped.completedCount == 0)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WidgetSnapshotStore(directory: dir)
        let rawJSON = #"{"completedCount":-2,"queueCount":-5,"savedBytes":-100}"#
        try Data(rawJSON.utf8).write(to: store.fileURL)

        let decoded = try #require(store.load())
        #expect(decoded.savedBytes == 0)
        #expect(decoded.queueCount == 0)
        #expect(decoded.completedCount == 0)
        #expect(decoded.isPaused == false)
    }

    @Test func corruptSnapshotReturnsNilWithoutThrowing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = WidgetSnapshotStore(directory: dir)
        try Data("not-json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        #expect(store.loadOrEmpty().hasSameContent(as: .empty))
    }

    @Test func saveIfChangedSkipsWritesWhenOnlyTimestampChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = WidgetSnapshotStore(directory: dir)
        let firstTime = Date(timeIntervalSince1970: 1_764_000_000)
        let secondTime = Date(timeIntervalSince1970: 1_764_000_500)

        let initial = WidgetSnapshot(
            savedBytes: 500, queueCount: 2, completedCount: 1, isPaused: false, updatedAt: firstTime)
        #expect(try store.saveIfChanged(initial) == true)

        let sameContentLater = WidgetSnapshot(
            savedBytes: 500, queueCount: 2, completedCount: 1, isPaused: false, updatedAt: secondTime)
        #expect(try store.saveIfChanged(sameContentLater) == false)
        // Stored timestamp was not rewritten.
        #expect(store.load()?.updatedAt == firstTime)

        let changedQueue = WidgetSnapshot(
            savedBytes: 500, queueCount: 1, completedCount: 2, isPaused: false, updatedAt: secondTime)
        #expect(try store.saveIfChanged(changedQueue) == true)
        #expect(store.load()?.queueCount == 1)
        #expect(store.load()?.completedCount == 2)
    }
}
