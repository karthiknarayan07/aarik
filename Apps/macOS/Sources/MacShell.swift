import AppCore
import AppKit
import AppServices
import AppUI
import Convert
import ConvertUI
import Foundation
import Observation
import PhotosLibrary
import QuickRunService
import SwiftUI

/// The Mac composition root: builds `AppServices`, `ConvertModel` and `ConvertMacScene`, and connects the
/// AppKit/Mac-only entry points (main window, menu bar, Dock, Services, Shortcuts) to them.
@MainActor
@Observable
final class MacShell {
    /// The one shell of the process: the window, quick runs, Dock drops and Open With all share its services.
    /// Created by `AppDelegate.init`, before any scene.
    static let shared = MacShell()

    let services: AppServices
    let convert: ConvertModel
    let scene: ConvertMacScene

    /// The sidebar column; the View menu and the toolbar button both change it.
    var sidebarVisibility = NavigationSplitViewVisibility.automatic
    /// The main window, owned by `AppDelegate` (see `MainWindowController`).
    @ObservationIgnored weak var mainWindow: NSWindow?

    /// The quick runs started from the menu bar (several can overlap), shown in its popover.
    var menuBarRuns = MenuBarRunBoard()
    /// Whether the menu bar popover is open; a run started there reports itself, so its banner is skipped then.
    @ObservationIgnored var isStatusPopoverVisible = false

    @ObservationIgnored let notifier = QueueNotifier()
    /// The quick runs of the last week, so their jobs get their own notification.
    @ObservationIgnored let quickRunStore: QuickRunStore
    @ObservationIgnored lazy var quickRun = makeQuickRun()
    /// The Shortcuts, Siri and Spotlight action: files or a selection of the libraries, as one quick run.
    @ObservationIgnored lazy var shrinkVideosAction = makeShrinkVideosAction()
    /// Told when an intent run arrives, so a launch it started stays windowless (set by `AppDelegate`).
    @ObservationIgnored var intentRunHandler: (@MainActor () -> Void)?

    init(
        directory: URL = MacShell.supportDirectory(), defaults: UserDefaults = .standard,
        photoStore: any PhotoStore = PhotoKitStore()
    ) {
        let services = AppServices(directory: directory, defaults: defaults, photoStore: photoStore)
        let convert = ConvertModel(services: services)
        self.services = services
        self.convert = convert
        self.scene = ConvertMacScene(model: convert)
        self.quickRunStore = QuickRunStore(directory: directory)
        // Quick runs announce themselves; the generic "Queue finished" is for the window's jobs.
        services.jobsExcludedFromRunSummary = { [quickRunStore] in quickRunStore.jobIDs }
        services.observeJobs { [weak self] jobs in
            self?.menuBarRuns.dropStale(presentJobs: Set(jobs.map(\.id)))
        }
        services.observeRunFinished { [weak self] summary in
            guard let self else { return }
            // Quiet only when the app is active with its window on screen; the Activity lists show the result.
            if NotificationPolicy.shouldPost(appIsActive: NSApp.isActive, windowOnScreen: self.isMainWindowVisible) {
                self.notifier.post(title: "Queue finished", body: ActivityText.notificationBody(summary))
            }
        }
        var host = ConvertHost()
        host.showMainWindow = { [weak self] in self?.showMainWindow() }
        host.undoManager = { [weak self] in self?.mainWindow?.undoManager }
        host.open = { urls in for url in urls { NSWorkspace.shared.open(url) } }
        host.reveal = { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) }
        host.showInPhotos = { identifier in
            if let url = PhotosDeepLink.assetURL(localIdentifier: identifier), NSWorkspace.shared.open(url) {
                return
            }
            // The address didn't open: at least bring Photos forward.
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        host.openPhotosAccessSettings = { PrivacySettings.open(PrivacySettings.photos) }
        host.beep = { NSSound.beep() }
        host.requestNotificationAuthorization = { [weak self] in self?.notifier.requestAuthorizationOnce() }
        convert.host = host
    }

    func start() async {
        await convert.start()
        await quickRun.start()
    }

    func prepareForTermination() async {
        await convert.prepareForTermination()
    }

    func showQueue() {
        convert.showQueue()
    }

    /// Application Support/<bundle id>.
    nonisolated static func supportDirectory() -> URL {
        // `-uiTesting <folder>` keeps a test launch away from the real library and queue. Debug builds only, and only
        // from the launch arguments: a Release build can't be pointed elsewhere, by argument or by a stored setting.
        #if DEBUG
            if let folder = LaunchArguments.value(of: "-uiTesting", in: ProcessInfo.processInfo.arguments) {
                return URL(filePath: folder, directoryHint: .isDirectory)
            }
        #endif
        return AppServices.supportDirectory(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
