import Foundation
import Synchronization
import Testing

@testable import AppCore

@Suite("Shared pause flag store")
struct SharedPauseFlagTests {
    private final class BundleToken {}

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-pause-flag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func bundleWithoutAppGroupReturnsNilStore() {
        let bundle = Bundle(for: BundleToken.self)
        #expect(SharedPauseFlagStore(bundle: bundle) == nil)
    }

    @Test func missingFlagDefaultsToRunningAndSkipsRedundantUnpausedWrite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SharedPauseFlagStore(directory: dir)
        #expect(store.load() == nil)
        #expect(store.isPaused == false)
        #expect(try store.setPaused(false, notify: false) == false)
        #expect(store.load() == nil)
    }

    @Test func setPausedWritesOnlyOnStateChange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SharedPauseFlagStore(directory: dir)
        let t1 = Date(timeIntervalSince1970: 1_764_000_000)
        let t2 = Date(timeIntervalSince1970: 1_764_000_100)

        #expect(try store.setPaused(true, updatedAt: t1, notify: false) == true)
        #expect(store.isPaused == true)
        #expect(store.load()?.updatedAt == t1)

        #expect(try store.setPaused(true, updatedAt: t2, notify: false) == false)
        #expect(store.load()?.updatedAt == t1)

        #expect(try store.setPaused(false, updatedAt: t2, notify: false) == true)
        #expect(store.isPaused == false)
        #expect(store.load()?.updatedAt == t2)
    }

    @Test func toggleFlipsStateAndPersistsAcrossReads() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SharedPauseFlagStore(directory: dir)
        let reader = SharedPauseFlagStore(directory: dir)

        #expect(try writer.toggle(notify: false) == true)
        #expect(reader.isPaused == true)

        #expect(try writer.toggle(notify: false) == false)
        #expect(reader.isPaused == false)
    }

    @Test func corruptFileDefaultsToFalse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SharedPauseFlagStore(directory: dir)
        try Data("corrupt".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        #expect(store.isPaused == false)
    }

    @Test func darwinNotificationFiresWhenNotifyIsTrueAndStopsWhenCancelled() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let notificationName = "test.queue.pause.\(UUID().uuidString)"
        let store = SharedPauseFlagStore(directory: dir, notificationName: notificationName)
        let count = Mutex(0)
        let observation = CrossProcessNotification.observe(name: notificationName) {
            count.withLock { $0 += 1 }
        }

        #expect(try store.setPaused(true, notify: true) == true)
        // Darwin notifications deliver on the main run loop / notify queue; poll briefly until received.
        for _ in 0..<50 {
            if count.withLock({ $0 }) > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(count.withLock { $0 } == 1)

        // Setting notify: false does not post.
        #expect(try store.setPaused(false, notify: false) == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(count.withLock { $0 } == 1)

        observation.cancel()
        #expect(try store.setPaused(true, notify: true) == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(count.withLock { $0 } == 1)
    }
}
