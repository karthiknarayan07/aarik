import AppCore
import Foundation
import Testing

@testable import iOSApp

@MainActor
struct LaunchPauseTests {
    private struct Environment {
        let flags: SharedPauseFlagStore
        let defaults: UserDefaults
        let cleanup: () -> Void
    }

    private func makeEnvironment() throws -> Environment {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "pause-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return Environment(
            flags: SharedPauseFlagStore(directory: directory), defaults: defaults,
            cleanup: {
                try? FileManager.default.removeItem(at: directory)
                defaults.removePersistentDomain(forName: suite)
            })
    }

    private func makeSync(_ env: Environment) -> WidgetSync {
        WidgetSync(
            reconciler: LaunchPauseReconciler(defaults: env.defaults), snapshotStore: nil, flagStore: env.flags,
            notificationName: nil, reloadTimelines: {}, reloadControls: {})
    }

    private func snapshot(paused: Bool) -> WidgetSnapshot {
        WidgetSnapshot(activity: ActivitySummary(jobs: []), isPaused: paused)
    }

    @Test func controlToggleWhileNotRunningWinsAtLaunch() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        // The last session ran unpaused and mirrored that to the flag.
        makeSync(env).sync(snapshot: snapshot(paused: false))
        // The app is not running: Control Center pauses the queue.
        try env.flags.setPaused(true, notify: false)

        // Next launch: the app's own value is "not paused" (auto-start on).
        let relaunched = makeSync(env)
        #expect(relaunched.launchPauseState(appPaused: false) == true)
        // Deciding does not write the flag, and syncing the winning value keeps it.
        #expect(env.flags.isPaused == true)
        relaunched.sync(snapshot: snapshot(paused: true))
        #expect(env.flags.isPaused == true)
    }

    @Test func controlResumeWhileNotRunningWinsOverAnAppPause() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        makeSync(env).sync(snapshot: snapshot(paused: true))
        try env.flags.setPaused(false, notify: false)

        #expect(makeSync(env).launchPauseState(appPaused: true) == false)
    }

    @Test func anUnchangedFlagLeavesTheAppsOwnValue() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        makeSync(env).sync(snapshot: snapshot(paused: false))

        // Auto-start was turned off since: the app starts paused, and its stale mirror does not undo that.
        #expect(makeSync(env).launchPauseState(appPaused: true) == true)
    }

    @Test func aFlagTheAppNeverWroteWins() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        try env.flags.setPaused(true, notify: false)
        #expect(makeSync(env).launchPauseState(appPaused: false) == true)
    }

    @Test func withNoFlagTheAppsValueStands() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        let sync = makeSync(env)
        #expect(sync.launchPauseState(appPaused: true) == true)
        #expect(sync.launchPauseState(appPaused: false) == false)
    }
}
