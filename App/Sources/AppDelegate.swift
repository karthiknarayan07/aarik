import AppKit
import PhotosLibrary

/// Owns the model and the updater for the app's lifetime: starts the queue at launch and lets work settle before
/// quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = Updater()
    private var isTerminating = false
    private var volumeObservers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Photos input left behind by a crash or quit; no job can be using it yet.
        let workFolder = WorkFolder.standard()
        Task.detached(priority: .utility) { workFolder.sweep() }
        Task { await model.start() }
        #if DEBUG
            if PhotosSpike.isRequested { PhotosSpike.start() }
        #endif
        // A drive coming or going changes which library files are there.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshLibrary() }
                })
        }
    }

    /// Files may have been moved, deleted or restored while the app was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshLibrary()
    }

    private func refreshLibrary() {
        let library = model.library
        Task { await library.refreshAvailability() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            // Pending library saves finish and the running job goes back to the queue for next launch.
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
