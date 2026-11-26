import AppCore
import Foundation
import Synchronization
import UIKit
import WidgetKit

/// Bridges queue state in the iOS app with the Home Screen widget and Control Center control via the App Group.
/// Writes snapshots and reloads timelines only when displayed values change (no polling).
@MainActor
public final class WidgetSync {
    private let snapshotStore: WidgetSnapshotStore?
    private let flagStore: SharedPauseFlagStore?
    private let notificationName: String?
    private let reloadTimelines: @MainActor () -> Void
    private let reloadControls: @MainActor () -> Void

    private let darwinObservation = Mutex<CrossProcessNotification.Observation?>(nil)
    private var activeTask: Task<Void, Never>?
    private var onPauseChange: (@MainActor (Bool) -> Void)?
    private var lastKnownSharedPause: Bool?
    let reconciler: LaunchPauseReconciler

    init(
        reconciler: LaunchPauseReconciler = LaunchPauseReconciler(),
        snapshotStore: WidgetSnapshotStore? = WidgetSnapshotStore(),
        flagStore: SharedPauseFlagStore? = SharedPauseFlagStore(),
        notificationName: String? = AppGroup.pauseNotificationName(),
        reloadTimelines: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        reloadControls: @escaping @MainActor () -> Void = {
            ControlCenter.shared.reloadControls(ofKind: WidgetKinds.pauseControl)
        }
    ) {
        self.reconciler = reconciler
        self.snapshotStore = snapshotStore
        self.flagStore = flagStore
        self.notificationName = notificationName
        self.reloadTimelines = reloadTimelines
        self.reloadControls = reloadControls
    }

    deinit {
        darwinObservation.withLock {
            $0?.cancel()
            $0 = nil
        }
        activeTask?.cancel()
    }

    /// Reads the current shared pause flag if one has been stored in the App Group.
    public func currentSharedPauseFlag() -> Bool? {
        flagStore?.load()?.isPaused
    }

    /// The pause state to start with: the shared flag wins over the app's own value when the control changed it while
    /// the app wasn't running. Call before the first `sync`, which would otherwise overwrite the flag.
    public func launchPauseState(appPaused: Bool) -> Bool {
        reconciler.resolve(appPaused: appPaused, shared: currentSharedPauseFlag())
    }

    /// Writes the latest queue activity and pause state to the App Group and reloads WidgetKit only on change.
    public func sync(activity: ActivitySummary, isPausedByUser: Bool) {
        let snapshot = WidgetSnapshot(activity: activity, isPaused: isPausedByUser)
        sync(snapshot: snapshot)
    }

    /// Writes `snapshot` to the App Group and reloads timelines/controls only when values actually changed.
    public func sync(snapshot: WidgetSnapshot) {
        if (try? snapshotStore?.saveIfChanged(snapshot)) == true {
            reloadTimelines()
        }
        if flagStore != nil { reconciler.recordWritten(snapshot.isPaused) }
        if (try? flagStore?.setPaused(snapshot.isPaused, notify: false)) == true {
            lastKnownSharedPause = snapshot.isPaused
            reloadControls()
        } else {
            lastKnownSharedPause = snapshot.isPaused
        }
    }

    /// Starts observing shared pause-flag changes from the Control Center extension via Darwin notification and
    /// foreground activation (no polling).
    public func startObserving(onPauseChange: @escaping @MainActor (Bool) -> Void) {
        stopObserving()
        self.onPauseChange = onPauseChange
        self.lastKnownSharedPause = flagStore?.isPaused

        if let notificationName {
            let observation = CrossProcessNotification.observe(name: notificationName) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refreshPauseFlag()
                }
            }
            darwinObservation.withLock { $0 = observation }
        }

        activeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard !Task.isCancelled else { return }
                self?.refreshPauseFlag()
            }
        }
    }

    /// Re-reads the shared pause flag from the App Group and invokes `onPauseChange` if it changed externally.
    public func refreshPauseFlag() {
        guard let current = flagStore?.isPaused else { return }
        guard current != lastKnownSharedPause else { return }
        lastKnownSharedPause = current
        onPauseChange?(current)
    }

    public func stopObserving() {
        darwinObservation.withLock {
            $0?.cancel()
            $0 = nil
        }
        activeTask?.cancel()
        activeTask = nil
        onPauseChange = nil
    }
}
