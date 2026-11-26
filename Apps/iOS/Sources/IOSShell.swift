import AppCore
import AppServices
import Convert
import ConvertUI
import Foundation
import Observation
import PhotosLibrary
import SwiftUI
import UIKit

/// The iOS composition root: builds `AppServices`, `ConvertModel` and `ConvertIOSScene`, filters tools by `.iOS`,
/// and wires the iOS platform host actions.
@MainActor
@Observable
final class IOSShell {
    let services: AppServices
    let convert: ConvertModel
    let scene: ConvertIOSScene
    let tools: [any Tool]
    private let backgroundRun: BackgroundRunCoordinator
    private let liveActivity: LiveActivityController
    /// Writes the widget snapshot and pause flag to the App Group when they change, and applies the control's toggle.
    private let widgetSync = WidgetSync()

    init(
        directory: URL = IOSShell.supportDirectory(),
        defaults: UserDefaults = .standard,
        photoStore: any PhotoStore = PhotoKitStore()
    ) {
        let services = AppServices(directory: directory, defaults: defaults, photoStore: photoStore)
        let convert = ConvertModel(services: services)
        self.services = services
        self.convert = convert
        self.scene = ConvertIOSScene(model: convert)
        self.tools = ToolRegistry.tools(for: .iOS, from: [convert.tool])
        self.backgroundRun = BackgroundRunCoordinator(services: services)
        self.liveActivity = LiveActivityController(services: services)

        var host = ConvertHost()
        host.open = { urls in
            for url in urls {
                UIApplication.shared.open(url)
            }
        }
        host.reveal = { urls in
            IOSFileRevealer().reveal(urls)
        }
        host.showInPhotos = { _ in
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        }
        host.openPhotosAccessSettings = {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        convert.host = host
    }

    func start() async {
        startWidgetSync()
        // A job left running by a crash or termination goes back to the queue when the queue loads; its partial
        // output lives in the Work folder, which is swept before anything starts.
        await BackgroundRunCoordinator.sweepWorkFolder()
        await convert.start()
        backgroundRun.start()
        liveActivity.start()
        pickUpStaged()
    }

    /// The app is the writer of the widget's snapshot: it writes on every queue change and every pause change, and
    /// the widget reloads only when a value changed. The control's toggle comes back as a pause change.
    private func startWidgetSync() {
        let services = services
        let sync = widgetSync
        sync.sync(activity: services.activity, isPausedByUser: services.isQueuePaused)
        services.observeJobs { [weak services] _ in
            guard let services else { return }
            sync.sync(activity: services.activity, isPausedByUser: services.isQueuePaused)
        }
        trackPause()
        sync.startObserving { [weak services] paused in
            services?.isQueuePaused = paused
        }
    }

    private func trackPause() {
        withObservationTracking {
            _ = services.isQueuePaused
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                widgetSync.sync(activity: services.activity, isPausedByUser: services.isQueuePaused)
                trackPause()
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            // Re-check Apple Intelligence availability and Photos access when returning to the foreground.
            convert.assistant.availability.refresh()
            Task { await convert.photos.start() }
            pickUpStaged()
        }
    }

    /// Picks up videos the share extension or the App Intent staged in the App Group, and hands them to Convert.
    func pickUpStaged() {
        Task { [services, scene] in
            await StagedPickup.shared.pickUp(into: scene, services: services)
        }
    }

    nonisolated static func supportDirectory() -> URL {
        #if DEBUG
            if let folder = LaunchArguments.value(of: "-uiTesting", in: ProcessInfo.processInfo.arguments) {
                return URL(filePath: folder, directoryHint: .isDirectory)
            }
        #endif
        return AppServices.supportDirectory(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
