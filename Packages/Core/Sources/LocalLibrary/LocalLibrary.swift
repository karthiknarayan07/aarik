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
    @ObservationIgnored private var pending: [(urls: [URL], scoped: [URL])] = []
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
    @ObservationIgnored private let inspect: Inspection
    /// Changed files that couldn't be read, with the stamp they had then: not tried again until it changes.
    @ObservationIgnored private var unreadable: [UUID: FileStamp] = [:]

    /// Says which files exist (not in a Trash), by item id; a seam so tests can hold a check while items change.
    typealias AvailabilityCheck = @Sendable ([(id: UUID, url: URL)]) async -> [UUID: Bool]
    /// Reads a changed file again (off the main actor); a seam so tests can count or fail it.
    typealias Inspection = @Sendable (URL) async -> ScannedFile?

    /// Restores what the store remembers; files that are gone come back with `isAvailable == false`.
    public convenience init(store: BookmarkStore, scanner: LibraryScanner = LibraryScanner(), batchSize: Int = 50) {
        self.init(
            store: store, scanner: scanner, batchSize: batchSize, availability: { await Self.availability(of: $0) })
    }

    init(
        store: BookmarkStore, scanner: LibraryScanner = LibraryScanner(), batchSize: Int = 50,
        availability: @escaping AvailabilityCheck,
        inspect: @escaping Inspection = { await LibraryScanner.inspectFile($0) }
    ) {
        self.store = store
        self.inspect = inspect
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
    /// in the library are skipped, and calls made while a scan runs are queued behind it. Security-scoped URLs (from
    /// an iOS document picker) are accessed synchronously before the caller returns and released once scanned.
    public func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        pending.append((urls: urls, scoped: scoped))
        isScanning = true
        if worker == nil {
            let id = UUID()
            workerID = id
            worker = Task { await drain(id) }
        }
    }

    /// The stored bookmark for an item, if one was created when the item was added.
    public func bookmark(for id: UUID) -> Data? {
        entries[id]?.bookmark
    }

    /// Stops the scan; items found before it stopped stay.
    public func cancelScan() {
        for batch in pending {
            for url in batch.scoped { url.stopAccessingSecurityScopedResource() }
        }
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
            unreadable[id] = nil
            if let key = keyByID.removeValue(forKey: id) { pathKeys.remove(key) }
        }
        persist()
    }

    /// Follows files renamed or moved in Finder to their new paths (`followMovedFiles`), re-checks which files
    /// still exist (not in a Trash), off the main actor, then reads again, in place, the files that changed on
    /// disk (`refreshChangedFiles`). Nothing is mounted and no UI is shown; a file on a disconnected drive is
    /// simply unavailable until the drive is back.
    public func refreshAvailability() async {
        await refreshExistence()
        await followMovedFiles()
        await refreshChangedFiles()
    }

    /// Items found missing from their path (by `refreshExistence`, which is the only check of the path) whose
    /// bookmark finds the file elsewhere (renamed or moved in Finder, not into a Trash) move there: same id, path
    /// and bookmark saved. Bookmarks are resolved off the main actor, and only for those items.
    private func followMovedFiles() async {
        let candidates = items.filter { !$0.isAvailable }.compactMap { item in
            item.fileURL.flatMap { url in entries[item.id].map { (id: item.id, url: url, entry: $0) } }
        }
        guard !candidates.isEmpty else { return }
        let moves = await Self.moves(of: candidates)
        var moved = false
        for move in moves {
            // The item may have changed meanwhile (removed, replaced, moved): only the one still at the old path,
            // with the entry that was resolved, moves; never onto another item's path.
            let newKey = LibraryScanner.pathKey(move.to)
            guard let index = items.firstIndex(where: { $0.id == move.id }), items[index].fileURL == move.from,
                let entry = entries[move.id], entry == move.entry, !pathKeys.contains(newKey),
                let item = LibraryItemBuilder.build(
                    url: move.to, inventory: entry.inventory, byteSize: entry.byteSize, id: move.id)
            else { continue }
            if let oldKey = keyByID[move.id] { pathKeys.remove(oldKey) }
            pathKeys.insert(newKey)
            keyByID[move.id] = newKey
            items[index] = item
            entries[move.id]?.path = move.to.path
            if let bookmark = move.bookmark { entries[move.id]?.bookmark = bookmark }
            moved = true
        }
        if moved { persist() }
    }

    /// For each file already known to be missing from its path, where its bookmark finds it now, when that is a
    /// different, existing path outside any Trash.
    @concurrent
    private nonisolated static func moves(of files: [(id: UUID, url: URL, entry: BookmarkStore.Entry)]) async
        -> [(id: UUID, from: URL, to: URL, bookmark: Data?, entry: BookmarkStore.Entry)]
    {
        files.compactMap { file in
            guard file.entry.bookmark != nil else { return nil }
            let resolved = BookmarkStore.resolve(file.entry)
            guard !resolved.isTrashed, resolved.url.path != file.url.path,
                FileManager.default.fileExists(atPath: resolved.url.path)
            else { return nil }
            return (
                file.id, file.url, resolved.url,
                resolved.refreshedBookmark ?? BookmarkStore.makeBookmark(for: resolved.url),
                file.entry
            )
        }
    }

    private func refreshExistence() async {
        let files = items.compactMap { item in item.fileURL.map { (id: item.id, url: $0) } }
        let checkedURLs = Dictionary(files.map { ($0.id, $0.url) }) { first, _ in first }
        let available = await availability(files)
        // Items may have changed meanwhile; only those still here at the path that was checked are updated (a
        // Replace may have moved one to a new path), in one change.
        var updated = items
        var changed = false
        for index in updated.indices {
            let item = updated[index]
            guard let isAvailable = available[item.id], checkedURLs[item.id] == item.fileURL,
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

    /// Reads again the available files whose size or modification date is no longer the stored one (edited or
    /// replaced outside the app, or stored wrong): same id, new size, metadata and badges, saved. Stamps are read
    /// and files inspected off the main actor. An entry stored before dates were kept counts as changed only when
    /// its size differs; otherwise its date is recorded.
    private func refreshChangedFiles() async {
        let files = items.filter(\.isAvailable).compactMap { item in
            item.fileURL.flatMap { url in entries[item.id].map { (id: item.id, url: url, stored: $0) } }
        }
        guard !files.isEmpty else { return }
        let stamps = await Self.stamps(of: files.map { (id: $0.id, url: $0.url) })
        var dated = false
        for file in files {
            guard let stamp = stamps[file.id] else { continue }
            let stored = file.stored
            if stored.modifiedAt == nil, stamp.size == stored.byteSize {
                if entries[file.id] == stored {
                    entries[file.id]?.modifiedAt = stamp.modified
                    dated = true
                }
                continue
            }
            guard !stamp.matches(size: stored.byteSize, modified: stored.modifiedAt), unreadable[file.id] != stamp
            else { continue }
            await readAgain(file.id, at: file.url, stamp: stamp, replacing: stored)
        }
        if dated { persist() }
    }

    /// Inspects the item's file again and updates it in place, unless the item moved, went away or was updated
    /// meanwhile (its entry is no longer `stored`), or the file can't be read; then `stamp` is remembered, so the
    /// file isn't tried again until it changes once more.
    private func readAgain(_ id: UUID, at url: URL, stamp: FileStamp, replacing stored: BookmarkStore.Entry) async {
        guard let scanned = await inspect(url) else {
            unreadable[id] = stamp
            return
        }
        unreadable[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].fileURL == url, entries[id] == stored,
            let item = LibraryItemBuilder.build(
                url: url, inventory: scanned.item.inventory, byteSize: scanned.item.byteSize, id: id)
        else { return }
        items[index] = item
        entries[id] = BookmarkStore.Entry(
            id: id, path: url.path, bookmark: scanned.bookmark ?? stored.bookmark, byteSize: item.byteSize,
            inventory: item.inventory, modifiedAt: scanned.modifiedAt)
        persist()
    }

    @concurrent
    private nonisolated static func stamps(of files: [(id: UUID, url: URL)]) async -> [UUID: FileStamp] {
        var result: [UUID: FileStamp] = [:]
        for file in files {
            result[file.id] = FileStamp.read(file.url)
        }
        return result
    }

    nonisolated static func checkAvailability(of files: [(id: UUID, url: URL)]) -> [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for file in files {
            let scoped = file.url.startAccessingSecurityScopedResource()
            defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
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
        guard let scanned, let replacementURL = scanned.item.fileURL else {
            await refreshAvailability()
            return
        }
        let item = LibraryItemBuilder.build(
            url: replacementURL, inventory: scanned.item.inventory, byteSize: scanned.item.byteSize, id: id)
        guard let item else { return }
        let newKey = LibraryScanner.pathKey(replacementURL)
        if newKey != key {
            // Another item already at the new path would make two entries for one file; keep the existing one.
            guard !pathKeys.contains(newKey) else { return }
            pathKeys.remove(key)
            pathKeys.insert(newKey)
            keyByID[id] = newKey
        }
        items[index] = item
        entries[id] = BookmarkStore.Entry(
            id: id, path: replacementURL.path, bookmark: scanned.bookmark, byteSize: item.byteSize,
            inventory: item.inventory,
            modifiedAt: scanned.modifiedAt)
        persist()
    }

    // MARK: - Scanning

    private func drain(_ id: UUID) async {
        while !pending.isEmpty, !Task.isCancelled, workerID == id {
            let batch = pending.removeFirst()
            await scanner.scan(batch.urls, excluding: pathKeys, batchSize: batchSize) { [weak self] found in
                await self?.receive(found)
            }
            for url in batch.scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard workerID == id else { return }
        for batch in pending {
            for url in batch.scoped { url.stopAccessingSecurityScopedResource() }
        }
        pending.removeAll()
        isScanning = false
        worker = nil
    }

    private func receive(_ batch: [ScannedFile]) {
        for file in batch {
            let item = file.item
            guard let url = item.fileURL else { continue }
            let key = LibraryScanner.pathKey(url)
            guard pathKeys.insert(key).inserted else { continue }
            keyByID[item.id] = key
            items.append(item)
            entries[item.id] = BookmarkStore.Entry(
                id: item.id, path: url.path, bookmark: file.bookmark, byteSize: item.byteSize,
                inventory: item.inventory, modifiedAt: file.modifiedAt)
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
            let key = LibraryScanner.pathKey(resolved.url)
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
