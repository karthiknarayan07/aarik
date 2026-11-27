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
    /// Which fetch task is the live one, so a cancelled old task finishing late leaves a newer one alone.
    @ObservationIgnored private var fetchGeneration = 0
    /// The access level the last started fetch ran under; a different one needs a new fetch.
    @ObservationIgnored private var fetchedAuthorization: PhotoAuthorization?

    /// Photos.sqlite is read on the Mac only (it needs Full Disk Access and isn't reachable on iOS). Elsewhere the frame
    /// rate, codec and range stay unknown until the video is local and inspected.
    public static let platformIndexLoader: IndexLoader = {
        #if os(macOS)
            await PhotosIndex().load()
        #else
            ([:], .notFound)
        #endif
    }

    public init(store: any PhotoStore, loadIndex: IndexLoader? = nil) {
        self.store = store
        self.loadIndex = loadIndex ?? Self.platformIndexLoader
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
            fetchedAuthorization = nil
            return
        }
        follow()
        // Limited to full access (or back) changes which videos exist, and no library change says so.
        if !hasLoaded || fetchedAuthorization != authorization { await fetchAndWait() }
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
        await rebuild()
    }

    // MARK: - Following changes

    private func follow() {
        guard observer == nil else { return }
        let changes = store.changes()
        observer = Task { [weak self] in
            for await _ in changes {
                self?.refetch()
                // At most about four refetches a second however often Photos reports a change (a sync can report
                // dozens); changes during the pause are folded into one.
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Fetches now, or after the fetch in flight: any number of requests while one runs make exactly one more.
    private func refetch() {
        guard fetchTask == nil else {
            fetchAgain = true
            return
        }
        fetchGeneration &+= 1
        let generation = fetchGeneration
        fetchTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                fetchAgain = false
                await fetchOnce(generation: generation)
            } while fetchAgain && !Task.isCancelled
            if fetchGeneration == generation { fetchTask = nil }
        }
    }

    private func fetchAndWait() async {
        refetch()
        await waitUntilIdle()
    }

    private func fetchOnce(generation: Int) async {
        isScanning = !hasLoaded
        defer { if fetchGeneration == generation { isScanning = false } }
        fetchedAuthorization = authorization
        do {
            let fetched = try await store.mediaAssets()
            guard !Task.isCancelled else { return }
            assets = fetched
            if shouldReadIndex(for: fetched) {
                await readIndex()
                guard !Task.isCancelled else { return }
            }
            await rebuild()
            hasLoaded = true
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = (error as? PhotoStoreError)?.errorDescription ?? "Couldn't read your Photos library."
        }
    }

    /// The index is read once, then again only when it was readable and a video appeared that it may not know yet.
    /// A failed read is not retried on every change (it copies a database); `reloadIndex()` retries it.
    private func shouldReadIndex(for fetched: [PhotoAsset]) -> Bool {
        switch indexStatus {
        case nil: true
        case .loaded: fetched.contains { $0.mediaKind == .video && !indexedIDs.contains($0.id) }
        default: false
        }
    }

    private func readIndex() async {
        let result = await loadIndex()
        indexEntries = result.entries
        indexStatus = result.status
        indexedIDs = Set(assets.map(\.id))
    }

    /// Builds the items off the main actor (thousands of them, and again after every change) and compares them there
    /// too; the main actor only assigns when something differs.
    private func rebuild() async {
        let assets = assets
        let entries = indexEntries
        let current = items
        let next = await Self.changedItems(assets, entries: entries, current: current)
        guard !Task.isCancelled, let next else { return }
        // Equal items keep the revision, so the grid and its caches aren't rebuilt for nothing.
        items = next
    }

    @concurrent
    private static func changedItems(
        _ assets: [PhotoAsset], entries: [String: PhotoIndexEntry], current: [LibraryItem]
    ) async -> [LibraryItem]? {
        let next = assets.map { asset in
            PhotoItemBuilder.build(
                asset, index: entries[PhotoItemBuilder.assetUUID(fromLocalIdentifier: asset.id).uppercased()])
        }
        return next == current ? nil : next
    }
}
