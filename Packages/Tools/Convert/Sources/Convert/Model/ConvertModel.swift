import AppCore
import AppServices
import AppUI
import Assistant
import Foundation
import LocalLibrary
import MediaEngine
import Observation
import PhotosLibrary

/// What the Convert tool needs from the platform it runs on, given by the shell. Each has a do-nothing default, so the
/// model works (and is tested) without a window. Nothing here names AppKit or UIKit.
@MainActor
public struct ConvertHost {
    /// Brings the main window to the front, showing it first when it was closed or minimized.
    public var showMainWindow: () -> Void = {}
    /// The window's undo manager, which Edit → Undo and Redo use.
    public var undoManager: () -> UndoManager? = { nil }
    /// Opens files in their default app.
    public var open: ([URL]) -> Void = { _ in }
    /// Shows files in the file manager, selected.
    public var reveal: ([URL]) -> Void = { _ in }
    /// Shows a video in Photos (by its local identifier); nothing in Photos changes.
    public var showInPhotos: (String) -> Void = { _ in }
    /// Opens the system's privacy settings, so a person can allow Photos access.
    public var openPhotosAccessSettings: () -> Void = {}
    public var beep: () -> Void = {}
    /// Asks, once per launch, to post notifications; called when the first job is added.
    public var requestNotificationAuthorization: () -> Void = {}

    public init() {}
}

/// The Convert tool's observable state and logic: the libraries' browsers, the choices that become a job, the loss
/// review, the Photos originals waiting to be deleted, and the pages' selection. The queue, the pressure rules, the
/// settings and the libraries themselves are the shared `AppServices`; this model uses them and owns no part of them.
@MainActor
@Observable
public final class ConvertModel {
    enum Keys {
        static let inspector = "window.inspectorPresented"
    }

    // MARK: Services

    public let services: AppServices
    @ObservationIgnored public let tool: ConvertTool
    /// What the platform provides: set by the shell once its window exists.
    @ObservationIgnored public var host = ConvertHost()

    // MARK: Navigation
    public var selection: VideoPage? = .localFiles {
        didSet {
            browser.filter = badgeFilter
            // A preview belongs to the page it was opened on.
            quickLookURL = nil
        }
    }
    public var isInspectorPresented: Bool {
        didSet { services.defaults.set(isInspectorPresented, forKey: Keys.inspector) }
    }
    public var isImporterPresented = false
    public var quickLookURL: URL?

    // MARK: Conversion choices
    public var preset: Preset {
        didSet { services.defaults.set(preset.rawValue, forKey: AppSettings.Keys.preset) }
    }
    public var compressPreset: CompressPreset {
        didSet { services.defaults.set(compressPreset.rawValue, forKey: AppSettings.Keys.compressPreset) }
    }
    public var isCompressPresented = false
    /// Presets chosen in the inspector for single videos; the header's `preset` is everyone else's (spec 8.2).
    /// Kept for the session.
    public var presetOverrides = PresetOverrides<UUID>()
    public var advanced = AdvancedOptions()
    public var saveLocation: SaveLocation
    /// Where the Videos page puts converted copies.
    public var photosSaveLocation = PhotosSaveLocation()

    // MARK: Replace, loss review and messages
    public var isConfirmingReplace = false
    /// Which job kind triggered the Replace confirmation, so confirming starts the same operation.
    @ObservationIgnored var pendingReplaceKind: ConvertJobKind = .shrink
    /// The first Replace in a session asks for confirmation; later ones don't, once videos were added with it.
    @ObservationIgnored public var replaceConsent = ReplaceConsent()
    /// Videos that would lose metadata, waiting for the user's decision before they are added (spec 8.4).
    public var lossReview: LossReview?
    /// A message for the user: something couldn't be added, was already queued, or the saved queue was unreadable.
    public var alert: AppAlert?

    // MARK: Libraries
    public let library: LocalLibrary
    /// Grouping, sort, search, filter and selection for the grid, with cached sections and savings.
    public let browser: LibraryBrowser
    /// The user's Photos videos, loaded when the Videos page first opens (never at launch).
    public let photos: PhotosLibrary
    /// The Videos page's own grouping, sort, search, filters and selection.
    public let photosBrowser: LibraryBrowser
    public let thumbnailSource: ThumbnailSource
    /// On-device Apple Intelligence features; every control hides while the model is unavailable.
    public let assistant: AssistantServices

    // MARK: Photos originals
    /// The originals in `services.pendingDeletions`, mirrored for the pending-deletion bar.
    public var pendingOriginals: [PendingDeletion] = []
    /// How the last attempt to move them to Recently Deleted went, until the next one.
    public var originalsNotice: OriginalsNotice?
    /// True from the delete call until Photos has answered (it waits for the user's confirmation).
    public var isMovingOriginals = false
    /// Originals pending when the user declined the confirmation; a run that adds none doesn't ask again.
    @ObservationIgnored var declinedOriginals: Set<String> = []
    /// Whether the app is currently in the foreground. Originals deletion is foreground-only because Photos requires
    /// a foreground system confirmation; iOS scenes update this from `scenePhase`.
    public var isForeground = true {
        didSet {
            if isForeground {
                let latest = services.pendingDeletions.all
                if pendingOriginals != latest { pendingOriginals = latest }
            }
        }
    }
    /// Completed Replace jobs already reflected in the library; nil until the first queue update, which seeds it
    /// with the jobs finished in earlier sessions.
    @ObservationIgnored var reconciledReplaceIDs: Set<UUID>?

    public init(services: AppServices) {
        self.services = services
        let defaults = services.defaults
        self.preset = defaults.string(forKey: AppSettings.Keys.preset).flatMap(Preset.init(rawValue:)) ?? .balanced
        self.compressPreset =
            defaults.string(forKey: AppSettings.Keys.compressPreset).flatMap(CompressPreset.init(rawValue:))
            ?? .balanced
        self.isInspectorPresented = defaults.object(forKey: Keys.inspector) as? Bool ?? true
        self.saveLocation = AppSettings.defaultSaveLocation(defaults)
        let library = services.library.local
        self.library = library
        self.browser = LibraryBrowser(collection: library)
        let photos = services.library.photos
        self.photos = photos
        self.photosBrowser = LibraryBrowser(collection: photos)
        self.thumbnailSource = services.library.thumbnailSource
        self.assistant = AssistantServices(client: services.assistantClient)
        self.pendingOriginals = services.pendingDeletions.all
        // The runner asks for the backup folder at each Replace, so the setting applies without rebuilding the queue.
        self.tool = ConvertTool(
            photoStore: services.library.photoStore, pendingDeletions: services.pendingDeletions,
            originalsBackup: AppSettings.originalsBackupProvider(defaults))
        services.register(tool)
        services.observeJobs { [weak self] jobs in self?.jobsChanged(jobs) }
        services.observeRunFinished { [weak self] _ in self?.moveOriginalsAfterRun() }
    }

    // MARK: Shared services, as the pages read them

    public var queue: JobQueue { services.queue }
    public var defaults: UserDefaults { services.defaults }
    public var pendingDeletions: PendingDeletions { services.pendingDeletions }
    public var photoStore: any PhotoStore { services.library.photoStore }
    public var jobs: [Job] { services.jobs }
    /// Counts, saved total and running progress for the Activity rows.
    public var activity: ActivitySummary { services.activity }
    public var isQueuePaused: Bool {
        get { services.isQueuePaused }
        set { services.isQueuePaused = newValue }
    }
    public var queuePause: QueuePause { services.queuePause }

    /// Starts the shared services (the queue, the pressure rules) and says so when the saved queue was unreadable.
    /// Safe to call more than once.
    public func start() async {
        await services.start()
        if let message = services.queueLoadError, alert == nil {
            alert = AppAlert(title: "Couldn't Read the Queue", message: message)
        }
    }

    /// Stops scanning (items found so far stay), lets library saves finish, and stops the queue before the app
    /// quits. The running job goes back to the queue and starts over next launch.
    public func prepareForTermination() async {
        library.cancelScan()
        await library.waitUntilIdle()
        await services.prepareForTermination()
    }

    /// Overview's "Allow access to Photos…": asks for access (the system prompt), then opens Videos, which shows
    /// the videos, or why there are none when access was refused.
    public func allowPhotos() {
        Task {
            await photos.requestAccess()
            selection = .photosVideos
        }
    }

    /// Adds files or folders dropped or picked by the user. Only reads them.
    public func addFiles(_ urls: [URL]) {
        library.add(urls)
        selection = .localFiles
    }

    /// Puts the Settings window's Save to default into the inspector.
    public func applyDefaultSaveLocation() {
        saveLocation = AppSettings.defaultSaveLocation(defaults)
    }
}

/// A titled message shown in an alert.
public struct AppAlert: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}
