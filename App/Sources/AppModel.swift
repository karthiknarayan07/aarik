import AppCore
import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary
import Observation
import PhotosLibrary

/// The composition root: the library, the job queue, and the window's shared state.
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let inspector = "window.inspectorPresented"
    }

    // MARK: Navigation and window
    var selection: SidebarDestination? = .localFiles {
        didSet { browser.filter = badgeFilter }
    }
    var isInspectorPresented: Bool {
        didSet { defaults.set(isInspectorPresented, forKey: Keys.inspector) }
    }
    var isImporterPresented = false
    var quickLookURL: URL?

    // MARK: Conversion choices
    var preset: Preset {
        didSet { defaults.set(preset.rawValue, forKey: AppSettings.Keys.preset) }
    }
    /// Presets chosen in the inspector for single videos; the header's `preset` is everyone else's (spec 8.2).
    /// Kept for the session.
    var presetOverrides = PresetOverrides<UUID>()
    var advanced = AdvancedOptions()
    var saveLocation: SaveLocation

    // MARK: Queue
    var jobs: [Job] = []
    /// Counts, saved total and running progress for the Activity rows, updated with `jobs`.
    var activity = ActivitySummary(jobs: [])
    var isQueuePaused = false
    var isConfirmingReplace = false
    /// The first Replace in a session asks for confirmation; later ones don't, once videos were added with it.
    @ObservationIgnored var replaceConsent = ReplaceConsent()
    /// Videos that would lose metadata, waiting for the user's decision before they are added (spec 8.4).
    var lossReview: LossReview?
    /// A message for the user: something couldn't be added, was already queued, or the saved queue was unreadable.
    var alert: AppAlert?

    let library: LocalLibrary
    /// Grouping, sort, search, filter and selection for the grid, with cached sections and savings.
    let browser: LibraryBrowser
    /// The user's Photos videos, loaded when the Videos page first opens (never at launch).
    let photos: PhotosLibrary
    /// The Videos page's own grouping, sort, search, filters and selection.
    let photosBrowser: LibraryBrowser
    let queue: JobQueue
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
        self.isInspectorPresented = defaults.object(forKey: Keys.inspector) as? Bool ?? true
        self.saveLocation = AppSettings.defaultSaveLocation(defaults)
        let library = LocalLibrary(directory: directory)
        self.library = library
        self.browser = LibraryBrowser(collection: library)
        let photos = PhotosLibrary(store: photoStore)
        self.photos = photos
        self.photosBrowser = LibraryBrowser(collection: photos)
        self.thumbnailSource = ThumbnailSource(cache: thumbnails, photos: photoStore)
        // The runner asks for the backup folder at each Replace, so the setting applies without rebuilding the queue.
        let runner = DownscaleRunner(originalsBackup: AppSettings.originalsBackupProvider(defaults))
        // With auto-start off the queue is paused from the start, so no enqueue can slip in before a pause.
        let autoStart = AppSettings.autoStartQueue(defaults)
        self.isQueuePaused = !autoStart
        self.queue = JobQueue(
            store: JobStore(directory: directory), runners: [DownscaleTool.toolID: runner], startPaused: !autoStart)
    }

    /// Application Support/<bundle id>.
    nonisolated static func supportDirectory() -> URL {
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
