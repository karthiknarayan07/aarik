import AppCore
import AppKit
import AppUI
import Assistant
import DownscaleVideo
import Foundation
import LocalLibrary
import MediaEngine
import Observation
import PhotosLibrary
import QuickRunService
import SwiftUI

/// The composition root: the library, the job queue, and the window's shared state.
@MainActor
@Observable
final class AppModel {
    /// The one model of the process: the window, quick runs, Dock drops and Open With all feed its queue. Created
    /// by `AppDelegate.init`, before any scene.
    static let shared = AppModel()

    private enum Keys {
        static let inspector = "window.inspectorPresented"
    }

    // MARK: Navigation and window
    var selection: SidebarDestination? = .localFiles {
        didSet { browser.filter = badgeFilter }
    }
    /// The sidebar column; the View menu and the toolbar button both change it.
    var sidebarVisibility = NavigationSplitViewVisibility.automatic
    var isInspectorPresented: Bool {
        didSet { defaults.set(isInspectorPresented, forKey: Keys.inspector) }
    }
    var isImporterPresented = false
    var quickLookURL: URL?
    /// The main window, owned by `AppDelegate` (see `MainWindowController`).
    @ObservationIgnored weak var mainWindow: NSWindow?

    // MARK: Conversion choices
    var preset: Preset {
        didSet { defaults.set(preset.rawValue, forKey: AppSettings.Keys.preset) }
    }
    /// Presets chosen in the inspector for single videos; the header's `preset` is everyone else's (spec 8.2).
    /// Kept for the session.
    var presetOverrides = PresetOverrides<UUID>()
    var advanced = AdvancedOptions()
    var saveLocation: SaveLocation
    /// Where the Videos page puts converted copies.
    var photosSaveLocation = PhotosSaveLocation()

    // MARK: Queue
    var jobs: [Job] = []
    /// Counts, saved total and running progress for the Activity rows, updated with `jobs`.
    var activity = ActivitySummary(jobs: [])
    /// The user's pause (the Pause button, auto-start off). The queue is also held, apart from this, while the Mac is
    /// hot or the battery is low: see `queuePause`.
    var isQueuePaused = false {
        didSet { refreshQueuePause() }
    }
    /// Whether the queue is paused and why, user and automatic together; its `statusText` is the status line.
    var queuePause = QueuePause(isPausedByUser: false, automatic: nil)
    /// How hard conversion works (Settings); thermal rules apply on top.
    var speed: SpeedSetting {
        didSet {
            defaults.set(speed.rawValue, forKey: AppSettings.Keys.speed)
            pressure.setSpeed(speed)
        }
    }
    /// Reads the thermal state and power source, keeps the Mac awake while the queue works, and tells the queue and
    /// the downscale limit what to do.
    @ObservationIgnored lazy var pressure = makePressure()
    @ObservationIgnored var lastThrottle: Task<Void, Never>?
    /// Holds an update's relaunch while a job runs or jobs are waiting; the updater asks it, the queue feeds it.
    @ObservationIgnored let relaunchGate = RelaunchGate()
    var isConfirmingReplace = false
    /// The first Replace in a session asks for confirmation; later ones don't, once videos were added with it.
    @ObservationIgnored var replaceConsent = ReplaceConsent()
    /// Videos that would lose metadata, waiting for the user's decision before they are added (spec 8.4).
    var lossReview: LossReview?
    /// A message for the user: something couldn't be added, was already queued, or the saved queue was unreadable.
    var alert: AppAlert?
    /// The current or most recent quick run started from the menu bar, shown in its popover.
    var quickRunStatus: QuickRunStatus?
    /// Whether the menu bar popover is open; a run started there reports itself, so its banner is skipped then.
    @ObservationIgnored var isStatusPopoverVisible = false

    let library: LocalLibrary
    /// Grouping, sort, search, filter and selection for the grid, with cached sections and savings.
    let browser: LibraryBrowser
    /// The user's Photos videos, loaded when the Videos page first opens (never at launch).
    let photos: PhotosLibrary
    /// The Videos page's own grouping, sort, search, filters and selection.
    let photosBrowser: LibraryBrowser
    let queue: JobQueue
    /// On-device Apple Intelligence features; every control hides while the model is unavailable.
    let assistant = AssistantServices()
    /// Photos originals whose copy is saved and verified, waiting for the batch delete.
    let pendingDeletions: PendingDeletions
    /// The originals in `pendingDeletions`, mirrored for the pending-deletion bar.
    var pendingOriginals: [PendingDeletion] = []
    /// How the last attempt to move them to Recently Deleted went, until the next one.
    var originalsNotice: OriginalsNotice?
    /// True from the delete call until Photos has answered (it waits for the user's confirmation).
    var isMovingOriginals = false
    /// Originals pending when the user declined the confirmation; a run that adds none doesn't ask again.
    @ObservationIgnored var declinedOriginals: Set<String> = []
    /// The saved queue couldn't be read, so its job list is incomplete and saved copies are not pruned by it.
    @ObservationIgnored var queueLoadFailed = false
    @ObservationIgnored let photoStore: any PhotoStore
    let thumbnails = ThumbnailCache()
    let thumbnailSource: ThumbnailSource
    let tools: [ToolEntry] = ToolRegistry.tools
    let comingSoonTools: [ToolEntry] = ToolRegistry.comingSoon

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var updatesTask: Task<Void, Never>?
    @ObservationIgnored var hasStarted = false
    /// The last command sent to the queue; each new one waits for it, so commands arrive in the order given.
    @ObservationIgnored var lastQueueCommand: Task<Void, Never>?
    @ObservationIgnored var runTracker = QueueRunTracker()
    @ObservationIgnored let notifier = QueueNotifier()
    /// The quick runs of the last week, so their jobs get their own notification (see `receive`).
    @ObservationIgnored let quickRunStore: QuickRunStore
    @ObservationIgnored lazy var quickRun = makeQuickRun()
    /// The Shortcuts, Siri and Spotlight action: files or a selection of the libraries, as one quick run.
    @ObservationIgnored lazy var shrinkVideosAction = makeShrinkVideosAction()
    /// Set once `start()` has finished; entry points that arrive earlier (an intent that launched the app) wait.
    @ObservationIgnored var hasFinishedStarting = false
    @ObservationIgnored var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// The app's own copies of videos that reached the action as data only. Not the Photos Work folder: that one is
    /// swept at every launch, this one keeps what a queued job still reads.
    @ObservationIgnored let stagedInputs: StagedInputs
    /// Copies whose jobs are queued; each is removed once none of its jobs is pending.
    @ObservationIgnored var stagedWatch: Set<URL> = []
    /// Told when an intent run arrives, so a launch it started stays windowless (set by `AppDelegate`).
    @ObservationIgnored var intentRunHandler: (@MainActor () -> Void)?
    /// Completed Replace jobs already reflected in the library; nil until the first queue update, which seeds it
    /// with the jobs finished in earlier sessions.
    @ObservationIgnored var reconciledReplaceIDs: Set<UUID>?

    init(
        directory: URL = AppModel.supportDirectory(), defaults: UserDefaults = .standard,
        photoStore: any PhotoStore = PhotoKitStore()
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.defaults = defaults
        self.preset =
            defaults.string(forKey: AppSettings.Keys.preset).flatMap(Preset.init(rawValue:)) ?? .balanced
        self.speed = AppSettings.speed(defaults)
        self.isInspectorPresented = defaults.object(forKey: Keys.inspector) as? Bool ?? true
        self.saveLocation = AppSettings.defaultSaveLocation(defaults)
        self.quickRunStore = QuickRunStore(fileURL: directory.appending(path: "quick-runs.json"))
        self.stagedInputs = StagedInputs(directory: directory.appending(path: "Staging", directoryHint: .isDirectory))
        let library = LocalLibrary(directory: directory)
        self.library = library
        self.browser = LibraryBrowser(collection: library)
        let photos = PhotosLibrary(store: photoStore)
        self.photos = photos
        self.photosBrowser = LibraryBrowser(collection: photos)
        self.thumbnailSource = ThumbnailSource(cache: thumbnails, photos: photoStore)
        self.photoStore = photoStore
        // The runner asks for the backup folder at each Replace, so the setting applies without rebuilding the queue.
        let backupProvider = AppSettings.originalsBackupProvider(defaults)
        let runner = DownscaleRunner(originalsBackup: backupProvider)
        let pendingDeletions = PendingDeletions(directory: directory)
        self.pendingDeletions = pendingDeletions
        self.pendingOriginals = pendingDeletions.all
        // Photos jobs fetch into the Work folder, which the launch sweep clears before the queue starts.
        let photosRunner = PhotosDownscaleRunner(
            store: photoStore, workFolder: .standard(), pendingDeletions: pendingDeletions,
            originalsBackup: backupProvider)
        // With auto-start off the queue is paused from the start, so no enqueue can slip in before a pause.
        let autoStart = AppSettings.autoStartQueue(defaults)
        self.isQueuePaused = !autoStart
        self.queue = JobQueue(
            store: JobStore(directory: directory),
            runners: [DownscaleTool.toolID: runner, DownscaleTool.photosToolID: photosRunner],
            startPaused: !autoStart)
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
        let id = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return URL.applicationSupportDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    /// The user-facing app name, read from the bundle so the brand never appears in code.
    nonisolated static var displayName: String {
        let info = Bundle.main
        return info.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? info.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// Overview's "Allow access to Photos…": asks for access (the system prompt), then opens Videos, which shows
    /// the videos, or why there are none when access was refused.
    func allowPhotos() {
        Task {
            await photos.requestAccess()
            selection = .photosVideos
        }
    }

    /// Adds files or folders dropped or picked by the user. Only reads them.
    func addFiles(_ urls: [URL]) {
        library.add(urls)
        selection = .localFiles
    }
}

/// A titled message shown in an alert.
struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
