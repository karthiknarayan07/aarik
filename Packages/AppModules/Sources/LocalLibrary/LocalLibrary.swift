import Foundation
import Observation

/// The user's local movie library: files and folders they added, scanned in the background and remembered
/// across launches. It only reads the user's files.
@MainActor
@Observable
public final class LocalLibrary {
    public private(set) var items: [LibraryItem] = [] {
        didSet { revision &+= 1 }
    }
    /// Changes whenever `items` does, so views and caches can tell cheaply that the library changed.
    public private(set) var revision = 0
    public private(set) var isScanning = false
    /// Set when the library file could not be read or written; the in-memory library keeps working.
    public private(set) var persistenceError: String?

    @ObservationIgnored private let store: BookmarkStore
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private let batchSize: Int
    @ObservationIgnored private var entries: [UUID: BookmarkStore.Entry] = [:]
    @ObservationIgnored private var pending: [[URL]] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Identifies the current worker, so a cancelled one finishing late cannot reset a newer scan's state.
    @ObservationIgnored private var workerID = UUID()
    /// Path key of every item, computed once per item and kept in step with `items`.
    @ObservationIgnored private var pathKeys = Set<String>()
    @ObservationIgnored private var keyByID: [UUID: String] = [:]
    @ObservationIgnored private let persistence: LibraryPersistence
    @ObservationIgnored private var saveDirty = false
    @ObservationIgnored private var saver: Task<Void, Never>?
    @ObservationIgnored private var cancelledWorkers: [Task<Void, Never>] = []
    @ObservationIgnored private var cachedBadgeCounts: (revision: Int, counts: [MediaBadge: Int])?
    @ObservationIgnored private let availability: AvailabilityCheck

    /// Says which files exist (not in a Trash), by item id; a seam so tests can hold a check while items change.
    typealias AvailabilityCheck = @Sendable ([(id: UUID, url: URL)]) async -> [UUID: Bool]

    /// Restores what the store remembers; files that are gone come back with `isAvailable == false`.
    public convenience init(store: BookmarkStore, scanner: LibraryScanner = LibraryScanner(), batchSize: Int = 50) {
        self.init(
            store: store, scanner: scanner, batchSize: batchSize, availability: { await Self.availability(of: $0) })
    }

    init(
        store: BookmarkStore, scanner: LibraryScanner = LibraryScanner(), batchSize: Int = 50,
        availability: @escaping AvailabilityCheck
    ) {
        self.store = store
        self.persistence = LibraryPersistence(store: store)
        self.scanner = scanner
        self.batchSize = batchSize
        self.availability = availability
        restore()
    }

    public convenience init(directory: URL, batchSize: Int = 50) {
        self.init(store: BookmarkStore(directory: directory), batchSize: batchSize)
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteSize } }

    /// How many items carry each badge; badges nobody has are absent.
    public var badgeCounts: [MediaBadge: Int] {
        if let cached = cachedBadgeCounts, cached.revision == revision { return cached.counts }
        let counts = items.reduce(into: [MediaBadge: Int]()) { counts, item in
            for badge in item.badges { counts[badge, default: 0] += 1 }
        }
        cachedBadgeCounts = (revision, counts)
        return counts
    }

    public func groups(by grouping: Grouping, sort: Sort, filter: MediaBadge?) -> [ItemGroup] {
        LibraryGrouper.groups(items, by: grouping, sort: sort, filter: filter)
    }

    // MARK: - Adding and removing

    /// Adds files, or the movies inside folders (recursively). Scanning happens in the background; files already
    /// in the library are skipped, and calls made while a scan runs are queued behind it.
    public func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(urls)
        isScanning = true
        if worker == nil {
            let id = UUID()
            workerID = id
            worker = Task { await drain(id) }
        }
    }

    /// Stops the scan; items found before it stopped stay.
    public func cancelScan() {
        pending.removeAll()
        if let worker {
            worker.cancel()
            cancelledWorkers.append(worker)
        }
        worker = nil
        isScanning = false
    }

    /// Returns once no scan is running or queued.
    public func waitUntilIdle() async {
        while true {
            let running = cancelledWorkers + (worker.map { [$0] } ?? []) + (saver.map { [$0] } ?? [])
            if running.isEmpty { return }
            for task in running { await task.value }
            cancelledWorkers.removeAll()
        }
    }

    /// Removes items from the library only; the files are untouched.
    public func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            entries[id] = nil
            if let key = keyByID.removeValue(forKey: id) { pathKeys.remove(key) }
        }
        persist()
    }

    /// Re-checks which files still exist (not in a Trash), off the main actor. Nothing is mounted and no UI is
    /// shown; a file on a disconnected drive is simply unavailable until the drive is back.
    public func refreshAvailability() async {
        let files = items.map { (id: $0.id, url: $0.url) }
        let checkedURLs = Dictionary(files.map { ($0.id, $0.url) }) { first, _ in first }
        let available = await availability(files)
        // Items may have changed meanwhile; only those still here at the path that was checked are updated (a
        // Replace may have moved one to a new path), in one change.
        var updated = items
        var changed = false
        for index in updated.indices {
            let item = updated[index]
            guard let isAvailable = available[item.id], checkedURLs[item.id] == item.url,
                item.isAvailable != isAvailable
            else { continue }
            updated[index].isAvailable = isAvailable
            changed = true
        }
        if changed { items = updated }
    }

    @concurrent
    private nonisolated static func availability(of files: [(id: UUID, url: URL)]) async -> [UUID: Bool] {
        checkAvailability(of: files)
    }

    nonisolated static func checkAvailability(of files: [(id: UUID, url: URL)]) -> [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for file in files {
            let exists = FileManager.default.fileExists(atPath: file.url.path)
            result[file.id] = exists && !BookmarkStore.isInTrash(file.url)
        }
        return result
    }

    /// After a Replace put `replacement` where the item for `original` was (usually the same path), updates that
    /// item in place: same id, the new file's size, metadata, badges and a fresh bookmark. Nothing happens when
    /// no item has `original`'s path, or when the replacement can't be read (the item is then re-checked).
    public func fileWasReplaced(at original: URL, by replacement: URL) async {
        await fileWasReplaced(at: [original], by: replacement)
    }

    /// `fileWasReplaced(at:by:)` for the first of `originals` that is an item's path: for example the file the run
    /// read (where its bookmark found it after a move in Finder), then the path the job was added with, which is
    /// where the item still is until the next launch.
    public func fileWasReplaced(at originals: [URL], by replacement: URL) async {
        let keys = originals.map(LibraryScanner.pathKey)
        guard
            let (id, key) = keys.lazy.compactMap({ key in
                self.keyByID.first(where: { $0.value == key }).map { ($0.key, key) }
            }).first
        else { return }
        let scanned = await LibraryScanner.inspectFile(replacement)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard let scanned else {
            await refreshAvailability()
            return
        }
        let item = LibraryItemBuilder.build(
            url: scanned.item.url, inventory: scanned.item.inventory, byteSize: scanned.item.byteSize, id: id)
        guard let item else { return }
        let newKey = LibraryScanner.pathKey(item.url)
        if newKey != key {
            // Another item already at the new path would make two entries for one file; keep the existing one.
            guard !pathKeys.contains(newKey) else { return }
            pathKeys.remove(key)
            pathKeys.insert(newKey)
            keyByID[id] = newKey
        }
        items[index] = item
        entries[id] = BookmarkStore.Entry(
            id: id, path: item.url.path, bookmark: scanned.bookmark, byteSize: item.byteSize, inventory: item.inventory)
        persist()
    }

    // MARK: - Scanning

    private func drain(_ id: UUID) async {
        while !pending.isEmpty, !Task.isCancelled, workerID == id {
            let urls = pending.removeFirst()
            await scanner.scan(urls, excluding: pathKeys, batchSize: batchSize) { [weak self] batch in
                await self?.receive(batch)
            }
        }
        guard workerID == id else { return }
        pending.removeAll()
        isScanning = false
        worker = nil
    }

    private func receive(_ batch: [ScannedFile]) {
        for file in batch {
            let item = file.item
            let key = LibraryScanner.pathKey(item.url)
            guard pathKeys.insert(key).inserted else { continue }
            keyByID[item.id] = key
            items.append(item)
            entries[item.id] = BookmarkStore.Entry(
                id: item.id, path: item.url.path, bookmark: file.bookmark, byteSize: item.byteSize,
                inventory: item.inventory)
        }
        persist()
    }

    // MARK: - Persistence

    private func restore() {
        let stored: [BookmarkStore.Entry]
        do {
            stored = try store.load()
        } catch {
            persistenceError = "Could not read the library: \(error.localizedDescription)"
            return
        }
        var refreshed = false
        for var entry in stored {
            let resolved = BookmarkStore.resolve(entry)
            if let bookmark = resolved.refreshedBookmark {
                entry.bookmark = bookmark
                entry.path = resolved.url.path
                refreshed = true
            }
            let available = !resolved.isTrashed && FileManager.default.fileExists(atPath: resolved.url.path)
            guard
                let item = LibraryItemBuilder.build(
                    url: resolved.url, inventory: entry.inventory, byteSize: entry.byteSize, id: entry.id,
                    isAvailable: available)
            else { continue }
            let key = LibraryScanner.pathKey(item.url)
            guard pathKeys.insert(key).inserted else { continue }
            keyByID[item.id] = key
            items.append(item)
            entries[entry.id] = entry
        }
        if refreshed { persist() }
    }

    /// Marks the library changed and makes sure a saver is running. Encoding and writing happen off the main
    /// actor, and changes made while a write is in flight collapse into one more write of the latest state.
    private func persist() {
        saveDirty = true
        guard saver == nil else { return }
        saver = Task { await saveLoop() }
    }

    private func saveLoop() async {
        while saveDirty {
            saveDirty = false
            let snapshot = items.compactMap { entries[$0.id] }
            persistenceError = await persistence.write(snapshot)
        }
        saver = nil
    }
}

/// Writes snapshots of the library off the main actor.
actor LibraryPersistence {
    private let store: BookmarkStore

    init(store: BookmarkStore) {
        self.store = store
    }

    /// Saves the snapshot atomically; returns a message when that failed.
    func write(_ entries: [BookmarkStore.Entry]) -> String? {
        do {
            try store.save(entries)
            return nil
        } catch {
            return "Could not save the library: \(error.localizedDescription)"
        }
    }
}
