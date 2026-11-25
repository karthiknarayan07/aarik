import Foundation
import LocalLibrary
import Observation

/// The user's Photos videos as a collection the grid can show: authorization, the first load, and a refetch when
/// the library changes.
///
/// Nothing is downloaded: items come from Photos' metadata and, for frame rate, codec and dynamic range, from
/// Photos' own index (`PhotosIndex`) when it can be read. Without that index those stay unknown and everything
/// else works.
///
/// Item ids are derived from the local identifier (`PhotoItemBuilder.itemID`, a SHA-256 based UUID), so the same
/// video keeps the same id across refetches and launches, which keeps selection and caches valid.
@MainActor
@Observable
public final class PhotosLibrary: MediaCollection {
    /// Reads Photos' index; a seam so tests never open a real library.
    public typealias IndexLoader = @Sendable () async -> (entries: [String: PhotoIndexEntry], status: PhotosIndexStatus)

    public private(set) var items: [LibraryItem] = [] {
        didSet { revision &+= 1 }
    }
    /// Changes whenever `items` does (a refetch that finds the same videos leaves it alone).
    public private(set) var revision = 0
    /// True while the first load runs.
    public private(set) var isScanning = false
    public private(set) var authorization: PhotoAuthorization = .notDetermined
    /// False until the first read of `authorization`, so a screen doesn't show the access prompt for a moment
    /// when access was already given.
    public private(set) var isAuthorizationKnown = false
    /// True once a fetch has finished, so an empty library can be told from one still loading.
    public private(set) var hasLoaded = false
    /// What went wrong with the last fetch, in plain words; the previous items stay shown.
    public private(set) var loadError: String?
    /// How reading Photos' index went; nil until it was tried.
    public private(set) var indexStatus: PhotosIndexStatus?

    public let store: any PhotoStore

    @ObservationIgnored private let loadIndex: IndexLoader
    @ObservationIgnored private var assets: [PhotoAsset] = []
    @ObservationIgnored private var indexEntries: [String: PhotoIndexEntry] = [:]
    /// Ids of the videos that existed when the index was last read; a video outside it may not be in the index.
    @ObservationIgnored private var indexedIDs: Set<String> = []
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var fetchAgain = false

    public init(store: any PhotoStore, loadIndex: IndexLoader? = nil) {
        self.store = store
        self.loadIndex = loadIndex ?? { await PhotosIndex().load() }
    }

    // MARK: - Authorization and loading

    /// Reads the current authorization (never shows the system prompt), and when Photos can be read, loads the
    /// videos once and starts following changes. Safe to call again, for example when the app becomes active
    /// after the user changed access in System Settings.
    public func start() async {
        authorization = await store.authorization()
        isAuthorizationKnown = true
        guard authorization.allowsReading else {
            stop()
            items = []
            hasLoaded = false
            return
        }
        follow()
        if !hasLoaded { await fetchAndWait() }
    }

    /// Asks for access (the system prompt shows the first time), then loads when it was given.
    public func requestAccess() async {
        authorization = await store.requestAuthorization()
        isAuthorizationKnown = true
        await start()
    }

    /// Stops following the library.
    public func stop() {
        observer?.cancel()
        observer = nil
        fetchTask?.cancel()
        fetchTask = nil
        fetchAgain = false
        isScanning = false
    }

    /// Returns once no fetch is running or waiting.
    public func waitUntilIdle() async {
        while let task = fetchTask { await task.value }
    }

    /// Reads Photos' index again, for when Full Disk Access was granted after the first try.
    public func reloadIndex() async {
        await readIndex()
        rebuild()
    }

    // MARK: - Following changes

    private func follow() {
        guard observer == nil else { return }
        let changes = store.changes()
        observer = Task { [weak self] in
            for await _ in changes {
                self?.refetch()
            }
        }
    }

    /// Fetches now, or after the fetch in flight: any number of requests while one runs make exactly one more.
    private func refetch() {
        guard fetchTask == nil else {
            fetchAgain = true
            return
        }
        fetchTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                fetchAgain = false
                await fetchOnce()
            } while fetchAgain && !Task.isCancelled
            fetchTask = nil
        }
    }

    private func fetchAndWait() async {
        refetch()
        await waitUntilIdle()
    }

    private func fetchOnce() async {
        isScanning = !hasLoaded
        defer { isScanning = false }
        do {
            let videos = try await store.videos()
            guard !Task.isCancelled else { return }
            assets = videos
            if shouldReadIndex(for: videos) {
                await readIndex()
                guard !Task.isCancelled else { return }
            }
            rebuild()
            hasLoaded = true
            loadError = nil
        } catch {
            loadError = (error as? PhotoStoreError)?.errorDescription ?? "Couldn't read your Photos library."
        }
    }

    /// The index is read once, then again only when it was readable and a video appeared that it may not know yet.
    /// A failed read is not retried on every change (it copies a database); `reloadIndex()` retries it.
    private func shouldReadIndex(for videos: [PhotoAsset]) -> Bool {
        switch indexStatus {
        case nil: true
        case .loaded: videos.contains { !indexedIDs.contains($0.id) }
        default: false
        }
    }

    private func readIndex() async {
        let result = await loadIndex()
        indexEntries = result.entries
        indexStatus = result.status
        indexedIDs = Set(assets.map(\.id))
    }

    private func rebuild() {
        let entries = indexEntries
        let next = assets.map { asset in
            PhotoItemBuilder.build(
                asset, index: entries[PhotoItemBuilder.assetUUID(fromLocalIdentifier: asset.id).uppercased()])
        }
        // Equal items keep the revision, so the grid and its caches aren't rebuilt for nothing.
        if next != items { items = next }
    }
}
