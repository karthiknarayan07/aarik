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
    let tools: [any Tool]
    /// One scene per tool offered on iOS; the shell knows only `Tool` and `IOSToolScene`.
    let scenes: [AnyIOSToolScene]
    /// Where a hand-off should land (Convert's Queue); the root view consumes it once it is showing the tabs, so a
    /// cold launch or the onboarding never loses or interrupts it.
    var pendingRoute: ToolRoute?
    private let backgroundRun: BackgroundRunCoordinator
    private let liveActivity: LiveActivityController
    /// Writes the widget snapshot and pause flag to the App Group when they change, and applies the control's toggle.
    private let widgetSync = WidgetSync()

    init(
        directory: URL = IOSShell.supportDirectory(),
        defaults: UserDefaults = .standard,
        photoStore: any PhotoStore = PhotoKitStore()
    ) {
        let services = AppServices(
            directory: directory, defaults: defaults, photoStore: photoStore,
            assistantClient: AppServices.assistantClient(arguments: ProcessInfo.processInfo.arguments))
        let convert = ConvertModel(services: services)
        self.services = services
        self.convert = convert
        let tools = ToolRegistry.tools(for: .iOS, from: [convert.tool])
        let offered = Set(tools.map(\.id))
        self.tools = tools
        self.scenes = [AnyIOSToolScene(ConvertIOSScene(model: convert))].filter { offered.contains($0.id) }
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
        startPerformanceProbe()
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
        // The control may have toggled the shared flag while the app wasn't running: it wins over the app's own
        // value, and must be read before the first sync writes the app's value over it.
        let launchPaused = sync.launchPauseState(appPaused: services.isQueuePaused)
        if launchPaused != services.isQueuePaused {
            services.isQueuePaused = launchPaused
            // `start()` resumes the queue only when it isn't paused; a pause has to reach the queue itself.
            if launchPaused { services.send { await $0.pause() } }
        }
        sync.sync(activity: services.activity, isPausedByUser: services.isQueuePaused)
        services.observeJobs { [weak services] _ in
            guard let services else { return }
            sync.sync(activity: services.activity, isPausedByUser: services.isQueuePaused)
        }
        trackPause()
        sync.startObserving { [weak services] paused in
            guard let services, services.isQueuePaused != paused else { return }
            services.isQueuePaused = paused
            services.send { queue in
                if paused { await queue.pause() } else { await queue.resume() }
            }
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

    /// Asks for Photos access (the onboarding's Photos screen); the system sheet shows only the first time.
    func requestPhotosAccess() async {
        await convert.photos.requestAccess()
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
        Task { [weak self, services, scenes] in
            let queue = { (id: String) in
                self?.pendingRoute = ToolRoute(toolID: id, page: IOSPage.queue.rawValue)
            }
            // Staged videos are videos: the first tool that accepts a file takes them.
            guard let scene = scenes.first(where: { $0.tool.accepts(.file(URL(filePath: "/staged.mov"))) }) else {
                return
            }
            #if DEBUG
                if let store = IOSShell.testHandoffStore() {
                    let picked = await StagedPickup.shared.pickUp(
                        into: { scene.receive($0) }, services: services, store: store)
                    if !picked.isEmpty { queue(scene.id) }
                    return
                }
            #endif
            let picked = await StagedPickup.shared.pickUp(into: { scene.receive($0) }, services: services)
            if !picked.isEmpty { queue(scene.id) }
        }
    }

    #if DEBUG
        /// UI tests stage a hand-off into this folder (`-uiTestingHandoff <folder>`) instead of the App Group, which a
        /// test process can't reach; the pickup is the same code path.
        nonisolated static func testHandoffStore() -> StagedInputs? {
            LaunchArguments.value(of: "-uiTestingHandoff", in: ProcessInfo.processInfo.arguments).map {
                StagedInputs(directory: URL(filePath: $0, directoryHint: .isDirectory))
            }
        }

        /// With `-uiTestingProbe <file>`, samples this process's memory and CPU into that file for the performance tests.
        private func startPerformanceProbe() {
            guard
                let path = LaunchArguments.value(of: "-uiTestingProbe", in: ProcessInfo.processInfo.arguments)
            else { return }
            PerformanceProbe.shared.start(writingTo: URL(filePath: path))
        }
    #else
        private func startPerformanceProbe() {}
    #endif

    nonisolated static func supportDirectory() -> URL {
        #if DEBUG
            if let folder = LaunchArguments.value(of: "-uiTesting", in: ProcessInfo.processInfo.arguments) {
                return URL(filePath: folder, directoryHint: .isDirectory)
            }
        #endif
        return AppServices.supportDirectory(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
