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
        static let preset = "downscale.preset"
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
        didSet { defaults.set(preset.rawValue, forKey: Keys.preset) }
    }
    var advanced = AdvancedOptions()
    var saveLocation = SaveLocation()

    // MARK: Queue
    var jobs: [Job] = []
    var isConfirmingReplace = false
    /// The first Replace in a session asks for confirmation; later ones don't.
    var hasConfirmedReplace = false
    var queueError: String?

    let library: LocalLibrary
    /// Grouping, sort, search, filter and selection for the grid, with cached sections and savings.
    let browser: LibraryBrowser
    let queue: JobQueue
    let thumbnails = ThumbnailCache()
    let tools: [ToolEntry] = ToolRegistry.tools
    let comingSoonTools: [ToolEntry] = ToolRegistry.comingSoon

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var updatesTask: Task<Void, Never>?
    @ObservationIgnored var hasStarted = false

    init(directory: URL = AppModel.supportDirectory(), defaults: UserDefaults = .standard) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.defaults = defaults
        self.preset = defaults.string(forKey: Keys.preset).flatMap(Preset.init(rawValue:)) ?? .balanced
        self.isInspectorPresented = defaults.object(forKey: Keys.inspector) as? Bool ?? true
        let library = LocalLibrary(directory: directory)
        self.library = library
        self.browser = LibraryBrowser(library: library)
        self.queue = JobQueue(
            store: JobStore(directory: directory), runners: [DownscaleTool.toolID: DownscaleRunner()])
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
