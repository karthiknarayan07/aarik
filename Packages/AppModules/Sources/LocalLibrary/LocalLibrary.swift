import Foundation
import Observation

/// The user's local movie library: files and folders they added, scanned in the background and remembered
/// across launches. It only reads the user's files.
@MainActor
@Observable
public final class LocalLibrary {
    public private(set) var items: [LibraryItem] = []
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
    @ObservationIgnored private var cancelledWorkers: [Task<Void, Never>] = []

    /// Restores what the store remembers; files that are gone come back with `isAvailable == false`.
    public init(store: BookmarkStore, scanner: LibraryScanner = LibraryScanner(), batchSize: Int = 50) {
        self.store = store
        self.scanner = scanner
        self.batchSize = batchSize
        restore()
    }

    public convenience init(directory: URL, batchSize: Int = 50) {
        self.init(store: BookmarkStore(directory: directory), batchSize: batchSize)
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteSize } }

    /// How many items carry each badge; badges nobody has are absent.
    public var badgeCounts: [MediaBadge: Int] {
        items.reduce(into: [:]) { counts, item in
            for badge in item.badges { counts[badge, default: 0] += 1 }
        }
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
            let running = cancelledWorkers + (worker.map { [$0] } ?? [])
            if running.isEmpty { return }
            for task in running { await task.value }
            cancelledWorkers.removeAll()
        }
    }

    /// Removes items from the library only; the files are untouched.
    public func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        for id in ids { entries[id] = nil }
        persist()
    }

    /// Re-checks which files still exist.
    public func refreshAvailability() {
        for index in items.indices {
            items[index].isAvailable = FileManager.default.fileExists(atPath: items[index].url.path)
        }
    }

    // MARK: - Scanning

    private func drain(_ id: UUID) async {
        while !pending.isEmpty, !Task.isCancelled, workerID == id {
            let urls = pending.removeFirst()
            let known = Set(items.map { LibraryScanner.pathKey($0.url) })
            await scanner.scan(urls, excluding: known, batchSize: batchSize) { [weak self] batch in
                await self?.receive(batch)
            }
        }
        guard workerID == id else { return }
        pending.removeAll()
        isScanning = false
        worker = nil
    }

    private func receive(_ batch: [ScannedFile]) {
        var known = Set(items.map { LibraryScanner.pathKey($0.url) })
        for file in batch {
            let item = file.item
            guard known.insert(LibraryScanner.pathKey(item.url)).inserted else { continue }
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
            let available = FileManager.default.fileExists(atPath: resolved.url.path)
            guard
                let item = LibraryItemBuilder.build(
                    url: resolved.url, inventory: entry.inventory, byteSize: entry.byteSize, id: entry.id,
                    isAvailable: available)
            else { continue }
            items.append(item)
            entries[entry.id] = entry
        }
        if refreshed { persist() }
    }

    private func persist() {
        do {
            try store.save(items.compactMap { entries[$0.id] })
            persistenceError = nil
        } catch {
            persistenceError = "Could not save the library: \(error.localizedDescription)"
        }
    }
}
