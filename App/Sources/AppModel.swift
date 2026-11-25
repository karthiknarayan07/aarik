import AppCore
import DownscaleVideo
import Foundation
import LocalLibrary
import Observation

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
    var advanced = AdvancedOptions()
    var saveLocation: SaveLocation

    // MARK: Queue
    var jobs: [Job] = []
    /// Counts, saved total and running progress for the Activity rows, updated with `jobs`.
    var activity = ActivitySummary(jobs: [])
    var isQueuePaused = false
    var isConfirmingReplace = false
    /// The first Replace in a session asks for confirmation; later ones don't.
    var hasConfirmedReplace = false
    /// Videos that would lose metadata, waiting for the user's decision before they are added (spec 8.4).
    var lossReview: LossReview?
    /// A message for the user: something couldn't be added, was already queued, or the saved queue was unreadable.
    var alert: AppAlert?

    let library: LocalLibrary
    /// Grouping, sort, search, filter and selection for the grid, with cached sections and savings.
    let browser: LibraryBrowser
    let queue: JobQueue
    let thumbnails = ThumbnailCache()
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

    init(directory: URL = AppModel.supportDirectory(), defaults: UserDefaults = .standard) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.defaults = defaults
        self.preset =
            defaults.string(forKey: AppSettings.Keys.preset).flatMap(Preset.init(rawValue:)) ?? .balanced
        self.isInspectorPresented = defaults.object(forKey: Keys.inspector) as? Bool ?? true
        self.saveLocation = AppSettings.defaultSaveLocation(defaults)
        let library = LocalLibrary(directory: directory)
        self.library = library
        self.browser = LibraryBrowser(library: library)
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
