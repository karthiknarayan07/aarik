import AVFoundation
import AppCore
import Foundation
import MediaTestSupport
import Testing

@testable import LocalLibrary

/// Shared fixtures: one encoded clip per kind is made once and copied, because encoding is the slow part.
enum Fixtures {
    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func clip(
        hdr: FixtureHDR = .sdr, width: Int = 320, height: Int = 180, fps: Int = 30, rotation: Int = 0,
        metadata: [String: String] = [:]
    ) async throws -> URL {
        var options = ClipOptions()
        options.width = width
        options.height = height
        options.fps = fps
        options.hdr = hdr
        options.includeAudio = false
        options.rotationDegrees = rotation
        options.quickTimeMetadata = metadata
        return try await FixtureFactory.makeClip(options)
    }

    @discardableResult
    static func copy(_ source: URL, into folder: URL, as name: String) throws -> URL {
        let destination = folder.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    @MainActor
    static func settle(_ library: LocalLibrary) async {
        await library.waitUntilIdle()
    }
}

@MainActor
@Suite struct LocalLibraryTests {
    @Test func addFolderFindsOnlyMovies() async throws {
        let source = try await Fixtures.clip()
        let folder = try Fixtures.tempDirectory()
        let nested = folder.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Fixtures.copy(source, into: folder, as: "a.mov")
        try Fixtures.copy(source, into: nested, as: "b.mov")
        try "not a movie".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try Fixtures.copy(source, into: folder, as: ".hidden.mov")

        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([folder])
        await Fixtures.settle(library)

        #expect(library.items.count == 2)
        #expect(Set(library.items.map(\.url.lastPathComponent)) == ["a.mov", "b.mov"])
        #expect(!library.isScanning)
    }

    @Test func addingTheSameFileTwiceKeepsOneItem() async throws {
        let source = try await Fixtures.clip()
        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([source, source])
        await Fixtures.settle(library)
        library.add([source.deletingLastPathComponent()])
        await Fixtures.settle(library)
        #expect(library.items.count == 1)
    }

    @Test func addingANonMovieFileIsIgnored() async throws {
        let folder = try Fixtures.tempDirectory()
        let text = folder.appending(path: "a.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([text])
        await Fixtures.settle(library)
        #expect(library.items.isEmpty)
    }

    @Test func badgesFromInventory() async throws {
        let hlg = try await Fixtures.clip(hdr: .hlg, width: 1280, height: 720)
        let sdr = try await Fixtures.clip(hdr: .sdr, width: 1280, height: 720)
        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([hlg, sdr])
        await Fixtures.settle(library)

        let hlgItem = try #require(library.items.first { $0.url.standardizedFileURL == hlg.standardizedFileURL })
        let sdrItem = try #require(library.items.first { $0.url.standardizedFileURL == sdr.standardizedFileURL })
        #expect(hlgItem.badges == [.dolbyVision, .hdr])
        #expect(sdrItem.badges == [.sdr])
        #expect(sdrItem.pixelSize == CGSize(width: 1280, height: 720))
        #expect(sdrItem.byteSize > 0)
        #expect(sdrItem.isAvailable)
        #expect(library.badgeCounts[.sdr] == 1)
        #expect(library.badgeCounts[.hdr] == 1)
        #expect(library.badgeCounts[.k4] == nil)
        #expect(library.totalBytes == hlgItem.byteSize + sdrItem.byteSize)
    }

    @Test func rotatedClipReportsDisplayOrientation() async throws {
        let clip = try await Fixtures.clip(width: 320, height: 180, rotation: 90)
        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([clip])
        await Fixtures.settle(library)
        #expect(library.items.first?.pixelSize == CGSize(width: 180, height: 320))
    }

    @Test func missingFileBecomesUnavailable() async throws {
        let folder = try Fixtures.tempDirectory()
        let clip = try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "gone.mov")
        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([clip])
        await Fixtures.settle(library)
        #expect(library.items.first?.isAvailable == true)

        try FileManager.default.removeItem(at: clip)
        await library.refreshAvailability()
        #expect(library.items.first?.isAvailable == false)

        // Back again (a drive reconnected): available again.
        try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "gone.mov")
        await library.refreshAvailability()
        #expect(library.items.first?.isAvailable == true)
    }

    @Test func replacedFileUpdatesItsEntryInPlace() async throws {
        let folder = try Fixtures.tempDirectory()
        let clip = try Fixtures.copy(try await Fixtures.clip(width: 640, height: 360), into: folder, as: "a.mov")
        let store = BookmarkStore(directory: try Fixtures.tempDirectory())
        let library = LocalLibrary(store: store)
        library.add([clip])
        await Fixtures.settle(library)
        let before = try #require(library.items.first)

        // A Replace put a smaller file at the original's path.
        let smaller = try await Fixtures.clip(width: 320, height: 180)
        try FileManager.default.removeItem(at: clip)
        try FileManager.default.copyItem(at: smaller, to: clip)
        let newSize = try #require(try clip.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        await library.fileWasReplaced(at: clip, by: clip)
        await Fixtures.settle(library)

        let after = try #require(library.items.first)
        #expect(library.items.count == 1)
        #expect(after.id == before.id)
        #expect(after.byteSize == Int64(newSize))
        #expect(after.inventory["video.dimensions"]?.value == "320x180")
        #expect(after.isAvailable)
        #expect(after != before)
        let entry = try #require(try store.load().first)
        #expect(entry.id == before.id)
        #expect(entry.byteSize == Int64(newSize))
        #expect(entry.inventory == after.inventory)
    }

    @Test func replacementUnderANewNameMovesTheEntry() async throws {
        let folder = try Fixtures.tempDirectory()
        let clip = try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "a.m4v")
        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([clip])
        await Fixtures.settle(library)
        let id = try #require(library.items.first?.id)

        let replacement = folder.appending(path: "a.mov")
        try FileManager.default.moveItem(at: clip, to: replacement)
        await library.fileWasReplaced(at: clip, by: replacement)

        #expect(library.items.map(\.id) == [id])
        #expect(library.items.first?.url.lastPathComponent == "a.mov")
        // The old path is free again: adding a file there makes a new entry.
        try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "a.m4v")
        library.add([clip])
        await Fixtures.settle(library)
        #expect(library.items.count == 2)
    }

    /// Holds a check until the test opens it.
    actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    @Test func availabilityCheckedForAnOldPathDoesNotApplyToTheItemsNewPath() async throws {
        let folder = try Fixtures.tempDirectory()
        let clip = try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "a.m4v")
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let gate = Gate()
        let library = LocalLibrary(
            store: BookmarkStore(directory: try Fixtures.tempDirectory()),
            availability: { files in
                startedContinuation.yield()
                await gate.wait()
                return LocalLibrary.checkAvailability(of: files)
            })
        library.add([clip])
        await Fixtures.settle(library)

        // A refresh reads the item's path; before its answer comes back, a Replace moves the item to a new path.
        let refresh = Task { await library.refreshAvailability() }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        let replacement = folder.appending(path: "a.mov")
        try FileManager.default.moveItem(at: clip, to: replacement)
        await library.fileWasReplaced(at: clip, by: replacement)
        await gate.open()
        await refresh.value

        #expect(library.items.first?.url.lastPathComponent == "a.mov")
        #expect(library.items.first?.isAvailable == true)
    }

    @Test func replacementOfAFileNotInTheLibraryChangesNothing() async throws {
        let folder = try Fixtures.tempDirectory()
        let clip = try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "a.mov")
        let other = try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "b.mov")
        let library = LocalLibrary(directory: try Fixtures.tempDirectory())
        library.add([clip])
        await Fixtures.settle(library)
        let before = library.items

        await library.fileWasReplaced(at: other, by: other)

        #expect(library.items == before)
    }

    @Test func removeDropsItemsAndPersists() async throws {
        let source = try await Fixtures.clip()
        let folder = try Fixtures.tempDirectory()
        try Fixtures.copy(source, into: folder, as: "a.mov")
        try Fixtures.copy(source, into: folder, as: "b.mov")
        let directory = try Fixtures.tempDirectory()
        let library = LocalLibrary(directory: directory)
        library.add([folder])
        await Fixtures.settle(library)
        let removed = try #require(library.items.first { $0.url.lastPathComponent == "a.mov" })
        library.remove([removed.id])
        await Fixtures.settle(library)
        #expect(library.items.map(\.url.lastPathComponent) == ["b.mov"])
        #expect(LocalLibrary(directory: directory).items.map(\.url.lastPathComponent) == ["b.mov"])
        // Only the library entry goes; both files stay on disk.
        #expect(FileManager.default.fileExists(atPath: removed.url.path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "b.mov").path))
    }

    @Test func bookmarksRoundTrip() async throws {
        let folder = try Fixtures.tempDirectory()
        let clip = try Fixtures.copy(try await Fixtures.clip(hdr: .hlg), into: folder, as: "kept.mov")
        let store = BookmarkStore(directory: try Fixtures.tempDirectory())
        let first = LocalLibrary(store: store)
        first.add([clip])
        await Fixtures.settle(first)

        let second = LocalLibrary(store: store)
        #expect(second.items.count == 1)
        #expect(second.items.first?.id == first.items.first?.id)
        #expect(second.items.first?.badges == first.items.first?.badges)
        #expect(second.items.first?.inventory == first.items.first?.inventory)
        #expect(second.items.first?.isAvailable == true)

        try FileManager.default.removeItem(at: clip)
        let third = LocalLibrary(store: store)
        #expect(third.items.count == 1)
        #expect(third.items.first?.isAvailable == false)
    }

    @Test func rapidBatchesCoalesceToTheFinalState() async throws {
        let source = try await Fixtures.clip(width: 160, height: 90)
        let folder = try Fixtures.tempDirectory()
        for index in 0..<30 { try Fixtures.copy(source, into: folder, as: "c\(index).mov") }
        let store = BookmarkStore(directory: try Fixtures.tempDirectory())
        let library = LocalLibrary(store: store, batchSize: 1)
        library.add([folder])
        await Fixtures.settle(library)
        #expect(library.items.count == 30)
        #expect(try store.load().map(\.id) == library.items.map(\.id))
        library.remove(Set(library.items.prefix(5).map(\.id)))
        await Fixtures.settle(library)
        #expect(try store.load().map(\.id) == library.items.map(\.id))
        #expect(library.persistenceError == nil)
    }

    @Test func trashedFileIsUnavailableAndItsPathIsNotPersisted() async throws {
        let folder = try Fixtures.tempDirectory()
        let clip = try Fixtures.copy(try await Fixtures.clip(), into: folder, as: "trash-me.mov")
        let store = BookmarkStore(directory: try Fixtures.tempDirectory())
        let library = LocalLibrary(store: store)
        library.add([clip])
        await Fixtures.settle(library)
        let originalPath = try #require(try store.load().first?.path)

        var trashed: NSURL?
        try FileManager.default.trashItem(at: clip, resultingItemURL: &trashed)
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed as URL) } }

        await library.refreshAvailability()
        #expect(library.items.first?.isAvailable == false)
        let restored = LocalLibrary(store: store)
        await Fixtures.settle(restored)
        #expect(restored.items.first?.isAvailable == false)
        #expect(try store.load().first?.path == originalPath)
    }

    @Test func cancellingTheScanKeepsWhatArrived() async throws {
        let source = try await Fixtures.clip(width: 160, height: 90)
        let folder = try Fixtures.tempDirectory()
        for index in 0..<6 { try Fixtures.copy(source, into: folder, as: "c\(index).mov") }
        let library = LocalLibrary(directory: try Fixtures.tempDirectory(), batchSize: 2)
        library.add([folder])
        library.cancelScan()
        await Fixtures.settle(library)
        #expect(!library.isScanning)
        #expect(library.items.count <= 6)
    }
}

@Suite struct LibraryScannerTests {
    private func folderOfClips(_ count: Int) async throws -> URL {
        let source = try await Fixtures.clip(width: 160, height: 90)
        let folder = try Fixtures.tempDirectory()
        for index in 0..<count { try Fixtures.copy(source, into: folder, as: String(format: "c%03d.mov", index)) }
        return folder
    }

    @Test func scanIsIncrementalAndCancellable() async throws {
        let folder = try await folderOfClips(100)
        let scanner = LibraryScanner()
        let batches = Locked<[Int]>([])

        // The callback runs on the scan's own task, so cancelling "the current task" from the first batch
        // cancels the scan at a deterministic point.
        await Task {
            await scanner.scan([folder], batchSize: 10) { batch in
                batches.withLock { $0.append(batch.count) }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }.value

        let sizes = batches.withLock { $0 }
        #expect(sizes == [10])
        #expect(sizes.reduce(0, +) < 100)
    }

    @Test func scanYieldsBatchesOfAtMostFifty() async throws {
        let folder = try await folderOfClips(60)
        let batches = Locked<[Int]>([])
        await LibraryScanner().scan([folder]) { batch in batches.withLock { $0.append(batch.count) } }
        #expect(batches.withLock { $0 } == [50, 10])
    }

    @Test func scanSkipsKnownPaths() async throws {
        let folder = try await folderOfClips(3)
        let known = LibraryScanner.pathKey(folder.appending(path: "c001.mov"))
        let names = Locked<[String]>([])
        await LibraryScanner().scan([folder], excluding: [known]) { batch in
            names.withLock { $0 += batch.map(\.item.url.lastPathComponent) }
        }
        #expect(names.withLock { $0 } == ["c000.mov", "c002.mov"])
    }
}

@Suite struct LibraryItemBuilderTests {
    private func inventory(
        dimensions: String = "1920x1080", fps: String = "30.00", transfer: String? = nil,
        transform: String = "1,0,0,1,0,0",
        extra: [MetadataItem] = []
    ) -> MetadataInventory {
        var items = [
            MetadataItem(key: "video.dimensions", category: .video, displayName: "Dimensions", value: dimensions),
            MetadataItem(key: "video.frameRate", category: .video, displayName: "Frame rate", value: fps),
            MetadataItem(key: "video.transform", category: .video, displayName: "Transform", value: transform),
            MetadataItem(key: "video.duration", category: .video, displayName: "Duration", value: "2500"),
        ]
        if let transfer {
            items.append(
                MetadataItem(key: "video.transferFunction", category: .video, displayName: "Transfer", value: transfer))
        }
        return MetadataInventory(items: items + extra)
    }

    private func build(_ inventory: MetadataInventory, url: URL = URL(filePath: "/nonexistent/clip.mov"))
        -> LibraryItem?
    {
        LibraryItemBuilder.build(url: url, inventory: inventory, byteSize: 10)
    }

    private func item(_ key: String, _ value: String) -> MetadataItem {
        MetadataItem(key: key, category: .other, displayName: key, value: value)
    }

    @Test func derivesBasicFields() throws {
        let built = try #require(build(inventory()))
        #expect(built.pixelSize == CGSize(width: 1920, height: 1080))
        #expect(built.frameRate == 30)
        #expect(built.duration == 2.5)
        #expect(built.badges == [.sdr])
    }

    @Test func fourKUsesShortSideAndDisplayOrientation() throws {
        #expect(try #require(build(inventory(dimensions: "3840x2160"))).badges == [.k4, .sdr])
        #expect(try #require(build(inventory(dimensions: "2160x3840", transform: "0,1,-1,0,0,0"))).badges.contains(.k4))
        #expect(try #require(build(inventory(dimensions: "1920x1080"))).badges.contains(.k4) == false)
        let portrait = try #require(build(inventory(dimensions: "3840x2160", transform: "0,1,-1,0,0,0")))
        #expect(portrait.pixelSize == CGSize(width: 2160, height: 3840))
    }

    @Test func hdrFromTransferFunction() throws {
        #expect(try #require(build(inventory(transfer: "ITU_R_2100_HLG"))).badges == [.hdr])
        #expect(try #require(build(inventory(transfer: "SMPTE_ST_2084_PQ"))).badges == [.hdr])
        #expect(try #require(build(inventory(transfer: "ITU_R_709_2"))).badges == [.sdr])
    }

    @Test func dolbyVisionSpatialSloMoCinematic() throws {
        let dv = try #require(build(inventory(extra: [item("hdr.dolbyVision", "profile 8.4")])))
        #expect(dv.badges == [.dolbyVision])
        #expect(try #require(build(inventory(extra: [item("hdr.stereo", "left+right")]))).badges == [.spatial, .sdr])
        #expect(try #require(build(inventory(fps: "120.00"))).badges == [.sloMo, .sdr])
        #expect(try #require(build(inventory(fps: "60.00"))).badges == [.sdr])
        #expect(
            try #require(build(inventory(extra: [item("track.2.kind", "auxv/dish")]))).badges == [.cinematic, .sdr])
        // A second ordinary video track is not Cinematic.
        #expect(try #require(build(inventory(extra: [item("track.2.kind", "vide/hvc1")]))).badges == [.sdr])
        #expect(
            try #require(build(inventory(extra: [item("timed.mdta/com.apple.quicktime.cinematic-video.x", "present")])))
                .badges == [.cinematic, .sdr])
        #expect(try #require(build(inventory(extra: [item("track.3.kind", "tmcd/tmcd")]))).badges == [.sdr])
    }

    @Test func editedFromSiblingAAE() throws {
        let folder = try Fixtures.tempDirectory()
        let clip = folder.appending(path: "IMG_0001.MOV")
        let plain = folder.appending(path: "IMG_0002.MOV")
        FileManager.default.createFile(atPath: clip.path, contents: Data())
        FileManager.default.createFile(atPath: plain.path, contents: Data())
        FileManager.default.createFile(atPath: folder.appending(path: "IMG_0001.AAE").path, contents: Data())
        #expect(try #require(build(inventory(), url: clip)).badges == [.edited, .sdr])
        #expect(try #require(build(inventory(), url: plain)).badges == [.sdr])
        FileManager.default.createFile(atPath: folder.appending(path: "IMG_O0002.AAE").path, contents: Data())
        #expect(try #require(build(inventory(), url: plain)).badges.contains(.edited))
    }

    @Test func captureDatePrefersQuickTimeThenFileSystem() throws {
        let qt = item("qt.com.apple.quicktime.creationdate", "2024-05-01T10:30:00+0530")
        let fs = item("fs.creationDate", "2020-01-01T00:00:00Z")
        let expected = Date(timeIntervalSince1970: 1_714_539_600)  // 2024-05-01T05:00:00Z
        #expect(try #require(build(inventory(extra: [fs, qt]))).captureDate == expected)
        #expect(
            try #require(build(inventory(extra: [item("qt.com.apple.quicktime.creationdate", "2024-05-01T05:00:00Z")])))
                .captureDate == expected)
        #expect(try #require(build(inventory(extra: [fs]))).captureDate == Date(timeIntervalSince1970: 1_577_836_800))
        #expect(try #require(build(inventory())).captureDate == nil)
    }

    @Test func inventoryWithoutVideoIsRejected() {
        #expect(build(MetadataInventory(items: [item("fs.creationDate", "2020-01-01T00:00:00Z")])) == nil)
    }
}

@Suite struct LibraryGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func make(_ name: String, bytes: Int64, date: String?, badges: Set<MediaBadge> = [.sdr]) -> LibraryItem {
        LibraryItem(
            id: UUID(), url: URL(filePath: "/x/\(name).mov"), byteSize: bytes, duration: 1,
            pixelSize: CGSize(width: 1920, height: 1080), frameRate: 30,
            captureDate: date.flatMap { try? Date($0, strategy: .iso8601) }, badges: badges, isAvailable: true,
            inventory: MetadataInventory())
    }

    private var items: [LibraryItem] {
        [
            make("jan-small", bytes: 10, date: "2025-01-10T12:00:00Z"),
            make("jan-big", bytes: 500, date: "2025-01-20T12:00:00Z", badges: [.hdr]),
            make("mar", bytes: 100, date: "2025-03-05T12:00:00Z"),
            make("old", bytes: 50, date: "2023-07-05T12:00:00Z"),
            make("undated", bytes: 5, date: nil),
        ]
    }

    private func names(_ group: ItemGroup) -> [String] {
        group.items.map { $0.url.deletingPathExtension().lastPathComponent }
    }

    @Test func groupsByMonthBiggestFirst() {
        let groups = LibraryGrouper.groups(items, by: .month, sort: .biggestFirst, filter: nil, calendar: calendar)
        #expect(groups.map(\.title) == ["March 2025", "January 2025", "July 2023", "Unknown date"])
        #expect(names(groups[1]) == ["jan-big", "jan-small"])
        #expect(groups[1].totalBytes == 510)
    }

    @Test func groupsByYearNewestFirst() {
        let groups = LibraryGrouper.groups(items, by: .year, sort: .newestFirst, filter: nil, calendar: calendar)
        #expect(groups.map(\.title) == ["2025", "2023", "Unknown date"])
        #expect(names(groups[0]) == ["mar", "jan-big", "jan-small"])
    }

    @Test func noGroupingIsOneGroup() {
        let groups = LibraryGrouper.groups(items, by: .none, sort: .biggestFirst, filter: nil, calendar: calendar)
        #expect(groups.count == 1)
        #expect(names(groups[0]) == ["jan-big", "mar", "old", "jan-small", "undated"])
        #expect(LibraryGrouper.groups([], by: .none, sort: .biggestFirst, filter: nil, calendar: calendar).isEmpty)
    }

    @Test func filterKeepsOnlyMatchingBadge() {
        let groups = LibraryGrouper.groups(items, by: .month, sort: .biggestFirst, filter: .hdr, calendar: calendar)
        #expect(groups.map(\.title) == ["January 2025"])
        #expect(names(groups[0]) == ["jan-big"])
    }

    @Test func libraryItemEqualityComparesWhatCanChangeAndHashesByID() {
        let a = make("a", bytes: 1, date: nil)
        var same = a
        same.isAvailable = a.isAvailable
        #expect(a == same)
        var missing = a
        missing.isAvailable = false
        #expect(a != missing)
        let replaced = LibraryItem(
            id: a.id, url: a.url, byteSize: 2, duration: a.duration, pixelSize: a.pixelSize, frameRate: a.frameRate,
            captureDate: a.captureDate, badges: a.badges, isAvailable: a.isAvailable, inventory: a.inventory)
        #expect(a != replaced)
        #expect(a.hashValue == replaced.hashValue)
    }
}

@Suite struct BookmarkStoreTests {
    @Test func missingFileLoadsEmpty() throws {
        let store = BookmarkStore(directory: try Fixtures.tempDirectory())
        #expect(try store.load().isEmpty)
    }

    @Test func saveThenLoad() throws {
        let directory = try Fixtures.tempDirectory().appending(path: "nested/dir", directoryHint: .isDirectory)
        let store = BookmarkStore(directory: directory)
        let entry = BookmarkStore.Entry(
            id: UUID(), path: "/a/b.mov", bookmark: Data([1, 2, 3]), byteSize: 7, inventory: MetadataInventory())
        try store.save([entry])
        #expect(try store.load() == [entry])
        #expect(store.fileURL.lastPathComponent == "library.json")
    }

    @Test func corruptFileIsMovedAsideAndLoadsEmpty() throws {
        let directory = try Fixtures.tempDirectory()
        let store = BookmarkStore(directory: directory)
        try Data("{not json".utf8).write(to: store.fileURL)
        #expect(try store.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "library.corrupt.json").path))
    }

    @Test func resolvesBookmarkAfterMove() throws {
        let folder = try Fixtures.tempDirectory()
        let original = folder.appending(path: "a.mov")
        FileManager.default.createFile(atPath: original.path, contents: Data("x".utf8))
        let bookmark = try #require(BookmarkStore.makeBookmark(for: original))
        let moved = folder.appending(path: "b.mov")
        try FileManager.default.moveItem(at: original, to: moved)
        let entry = BookmarkStore.Entry(
            id: UUID(), path: original.path, bookmark: bookmark, byteSize: 1, inventory: MetadataInventory())
        let resolved = BookmarkStore.resolve(entry)
        #expect(resolved.url.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        #expect(resolved.refreshedBookmark != nil)  // the path changed, so the bookmark is re-created
    }

    @Test func fallsBackToStoredPathWhenBookmarkFails() {
        let entry = BookmarkStore.Entry(
            id: UUID(), path: "/definitely/not/here.mov", bookmark: Data([0]), byteSize: 1,
            inventory: MetadataInventory())
        #expect(BookmarkStore.resolve(entry).url.path == "/definitely/not/here.mov")
    }
}

@Suite struct ThumbnailCacheTests {
    @Test func producesBoundedThumbnailAndCaches() async throws {
        let clip = try await Fixtures.clip(width: 640, height: 360)
        let cache = ThumbnailCache()
        let image = try #require(await cache.thumbnail(for: clip, maxPixel: 320))
        #expect(max(image.width, image.height) <= 320)
        #expect(image.width > image.height)
        #expect(await cache.cachedCount == 1)
        _ = await cache.thumbnail(for: clip, maxPixel: 320)
        #expect(await cache.cachedCount == 1)
    }

    @Test func appliesPreferredTransform() async throws {
        let clip = try await Fixtures.clip(width: 640, height: 360, rotation: 90)
        let image = try #require(await ThumbnailCache().thumbnail(for: clip, maxPixel: 320))
        #expect(image.height > image.width)
    }

    @Test func missingFileGivesNil() async {
        #expect(await ThumbnailCache().thumbnail(for: URL(filePath: "/nope/missing.mov"), maxPixel: 320) == nil)
    }
}

/// Minimal lock-protected box for collecting results from `@Sendable` callbacks in tests.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
