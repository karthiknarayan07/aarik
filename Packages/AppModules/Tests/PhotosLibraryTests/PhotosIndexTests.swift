import AppCore
import Foundation
import LocalLibrary
import SQLite3
import Testing

@testable import PhotosLibrary

/// A fake `X.photoslibrary` in a temporary folder whose `database/Photos.sqlite` is built from SQL.
private final class FakeLibrary {
    let root: URL
    let library: URL
    var database: URL { library.appending(path: "database/Photos.sqlite") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "index-tests-\(UUID().uuidString)")
        library = root.appending(path: "Test.photoslibrary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: library.appending(path: "database"), withIntermediateDirectories: true)
    }

    deinit {
        chmod(database.path, 0o644)
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs the statements on the database and closes it.
    func write(_ sql: String) throws {
        let handle = try open()
        defer { sqlite3_close(handle) }
        try Self.exec(handle, sql)
    }

    /// An open connection the caller closes.
    func open() throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw FixtureError(message: "open failed")
        }
        return handle
    }

    static func exec(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    var index: PhotosIndex { PhotosIndex(libraryURL: library) }

    /// The names in the database folder, to check nothing was written next to the database.
    func databaseFolderNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: library.appending(path: "database").path))
    }
}

private struct FixtureError: Error {
    let message: String
}

private enum Schema {
    static let asset =
        "CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID VARCHAR, ZKIND INTEGER, ZTRASHEDSTATE INTEGER, ZHDRTYPE INTEGER);"
    /// `ZCODEC` has no declared type, so an integer stays an integer.
    static let attributes = """
        CREATE TABLE ZEXTENDEDATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZFPS FLOAT, ZCODEC, ZBITRATE FLOAT);
        """
    static let attributesWithoutFPS = """
        CREATE TABLE ZEXTENDEDATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZCODEC VARCHAR, ZBITRATE FLOAT);
        """
    /// `hvc1` as a 32-bit integer.
    static let hvc1 = 0x6876_6331
    /// `avc1` as a 32-bit integer.
    static let avc1 = 0x6176_6331
}

@Suite struct PhotosIndexTests {
    @Test func readsVideosWithTextAndIntegerCodecs() async throws {
        let fake = try FakeLibrary()
        try fake.write(
            Schema.asset + Schema.attributes + """
                INSERT INTO ZASSET VALUES (1, 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 5);
                INSERT INTO ZASSET VALUES (2, 'AAAAAAAA-0000-0000-0000-000000000002', 1, 0, 0);
                INSERT INTO ZASSET VALUES (3, 'AAAAAAAA-0000-0000-0000-000000000003', 1, 0, NULL);
                INSERT INTO ZASSET VALUES (4, 'AAAAAAAA-0000-0000-0000-000000000004', 0, 0, 10);
                INSERT INTO ZASSET VALUES (5, 'AAAAAAAA-0000-0000-0000-000000000005', 1, 1, 0);
                INSERT INTO ZASSET VALUES (6, 'AAAAAAAA-0000-0000-0000-000000000006', 1, 0, 0);
                INSERT INTO ZASSET VALUES (7, 'AAAAAAAA-0000-0000-0000-000000000007', 1, 0, 0);
                INSERT INTO ZEXTENDEDATTRIBUTES VALUES (11, 1, 59.94, 'hvc1', 24000000.0);
                INSERT INTO ZEXTENDEDATTRIBUTES VALUES (12, 2, 30.0, \(Schema.avc1), NULL);
                INSERT INTO ZEXTENDEDATTRIBUTES VALUES (13, 3, 0.0, NULL, 0.0);
                INSERT INTO ZEXTENDEDATTRIBUTES VALUES (14, 4, 0, 'jpeg', 1.0);
                INSERT INTO ZEXTENDEDATTRIBUTES VALUES (15, 5, 24.0, 'hvc1', 1.0);
                INSERT INTO ZEXTENDEDATTRIBUTES VALUES (16, 6, 25.0, '\(Schema.hvc1)', NULL);
                """)
        let (entries, status) = await fake.index.load()
        #expect(status == .loaded(count: 5))
        #expect(
            entries == [
                "AAAAAAAA-0000-0000-0000-000000000001": PhotoIndexEntry(
                    fps: 59.94, codec: "hvc1", bitRate: 24_000_000, hdrType: 5),
                "AAAAAAAA-0000-0000-0000-000000000002": PhotoIndexEntry(fps: 30, codec: "avc1", hdrType: 0),
                "AAAAAAAA-0000-0000-0000-000000000003": PhotoIndexEntry(),
                "AAAAAAAA-0000-0000-0000-000000000006": PhotoIndexEntry(fps: 25, codec: "hvc1", hdrType: 0),
                "AAAAAAAA-0000-0000-0000-000000000007": PhotoIndexEntry(hdrType: 0),
            ])
    }

    @Test func missingColumnsReadAsUnknown() async throws {
        let fake = try FakeLibrary()
        try fake.write(
            """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID VARCHAR);
            """ + Schema.attributesWithoutFPS + """
                INSERT INTO ZASSET VALUES (1, 'AAAAAAAA-0000-0000-0000-000000000001');
                INSERT INTO ZEXTENDEDATTRIBUTES VALUES (11, 1, 'hvc1', 8000000.0);
                """)
        let (entries, status) = await fake.index.load()
        #expect(status == .loaded(count: 1))
        #expect(
            entries["AAAAAAAA-0000-0000-0000-000000000001"] == PhotoIndexEntry(codec: "hvc1", bitRate: 8_000_000))
    }

    @Test func missingAttributesTableIsUnreadable() async throws {
        let fake = try FakeLibrary()
        try fake.write(Schema.asset + "INSERT INTO ZASSET VALUES (1, 'A', 1, 0, 0);")
        let (entries, status) = await fake.index.load()
        #expect(entries.isEmpty)
        guard case .unreadable(let reason) = status else {
            Issue.record("expected unreadable, got \(status)")
            return
        }
        #expect(reason.contains("ZEXTENDEDATTRIBUTES"))
    }

    @Test func missingAssetTableIsUnreadable() async throws {
        let fake = try FakeLibrary()
        try fake.write(Schema.attributes)
        let (entries, status) = await fake.index.load()
        #expect(entries.isEmpty)
        #expect(status == .unreadable("The ZASSET table is missing."))
    }

    @Test func fileThatIsNotADatabaseIsUnreadable() async throws {
        let fake = try FakeLibrary()
        try Data(repeating: 0x41, count: 4096).write(to: fake.database)
        let (entries, status) = await fake.index.load()
        #expect(entries.isEmpty)
        guard case .unreadable = status else {
            Issue.record("expected unreadable, got \(status)")
            return
        }
    }

    @Test func missingLibraryIsNotFound() async {
        let missing = FileManager.default.temporaryDirectory.appending(
            path: "no-such-\(UUID().uuidString).photoslibrary")
        let (entries, status) = await PhotosIndex(libraryURL: missing).load()
        #expect(entries.isEmpty)
        #expect(status == .notFound)
    }

    @Test func unreadableDatabaseIsNoAccess() async throws {
        let fake = try FakeLibrary()
        try fake.write(Schema.asset + Schema.attributes)
        #expect(chmod(fake.database.path, 0) == 0)
        let (entries, status) = await fake.index.load()
        #expect(entries.isEmpty)
        #expect(status == .noAccess)
    }

    /// Rows still in the write-ahead log (Photos keeps its database open) are read, and nothing is written next to
    /// the real database.
    @Test func readsTheWriteAheadLogWithoutTouchingTheSource() async throws {
        let fake = try FakeLibrary()
        try fake.write("PRAGMA journal_mode=WAL;" + Schema.asset + Schema.attributes)
        let writer = try fake.open()
        defer { sqlite3_close(writer) }
        try FakeLibrary.exec(writer, "PRAGMA wal_autocheckpoint=0;")
        try FakeLibrary.exec(
            writer,
            """
            INSERT INTO ZASSET VALUES (1, 'AAAAAAAA-0000-0000-0000-000000000001', 1, 0, 5);
            INSERT INTO ZEXTENDEDATTRIBUTES VALUES (11, 1, 30.0, 'hvc1', NULL);
            """)
        let before = try fake.databaseFolderNames()
        #expect(before.contains("Photos.sqlite-wal"))
        let sourceBytes = try Data(contentsOf: fake.database)

        let (entries, status) = await fake.index.load()
        #expect(status == .loaded(count: 1))
        #expect(entries["AAAAAAAA-0000-0000-0000-000000000001"]?.fps == 30)
        #expect(try fake.databaseFolderNames() == before)
        #expect(try Data(contentsOf: fake.database) == sourceBytes)
    }

    @Test func errorsMapToStatuses() {
        let noFile = CocoaError(.fileReadNoSuchFile, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOENT)])
        #expect(PhotosIndex.status(for: noFile) == .notFound)
        let denied = CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        #expect(PhotosIndex.status(for: denied) == .noAccess)
        #expect(PhotosIndex.status(for: CocoaError(.fileReadNoPermission)) == .noAccess)
        guard case .unreadable = PhotosIndex.status(for: CocoaError(.fileReadCorruptFile)) else {
            Issue.record("expected unreadable")
            return
        }
    }
}

@Suite struct PhotoItemBuilderIndexTests {
    @Test func entryGivesFrameRateCodecAndRange() {
        let entry = PhotoIndexEntry(fps: 59.94, codec: "hvc1", bitRate: 20_000_000, hdrType: 5)
        let item = PhotoItemBuilder.build(Samples.asset(width: 3840, height: 2160), index: entry)
        #expect(item.frameRate == 59.94)
        #expect(item.badges == [.k4, .hdr])
        #expect(item.inventory["video.codec"]?.value == "hvc1")
        #expect(CodecFamily(item: item) == .hevc)
        #expect(DynamicRange(badges: item.badges) == .hdr)
    }

    @Test func zeroHDRTypeIsSDR() {
        let item = PhotoItemBuilder.build(Samples.asset(), index: PhotoIndexEntry(fps: 30, codec: "avc1", hdrType: 0))
        #expect(item.badges == [.sdr])
        #expect(CodecFamily(item: item) == .h264)
    }

    @Test func unknownsStayUnknown() {
        let item = PhotoItemBuilder.build(Samples.asset(), index: PhotoIndexEntry())
        #expect(item.frameRate == 0)
        #expect(item.badges.isEmpty)
        #expect(item.inventory == MetadataInventory())
    }

    @Test func noEntryMatchesTheBasicBuild() {
        let asset = Samples.asset(subtypes: .highFrameRate)
        #expect(PhotoItemBuilder.build(asset, index: nil) == PhotoItemBuilder.build(asset))
    }

    @Test(arguments: [
        ("6F1B8A2C-1D3E-4F5A-9B7C-0E2D4F6A8B1C/L0/001", "6F1B8A2C-1D3E-4F5A-9B7C-0E2D4F6A8B1C"),
        ("PLAIN", "PLAIN"),
        ("/L0/001", ""),
    ])
    func assetUUIDIsThePartBeforeTheFirstSlash(identifier: String, uuid: String) {
        #expect(PhotoItemBuilder.assetUUID(fromLocalIdentifier: identifier) == uuid)
    }
}
