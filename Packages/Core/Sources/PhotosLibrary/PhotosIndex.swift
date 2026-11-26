import Darwin
import Foundation
import SQLite3

/// What Photos' own index knows about one video that PhotoKit doesn't say.
public struct PhotoIndexEntry: Sendable, Equatable {
    /// Frames per second; nil when unknown.
    public var fps: Double?
    /// Four-character codec code, such as `hvc1` or `avc1`; nil when unknown.
    public var codec: String?
    /// Bits per second; nil when unknown.
    public var bitRate: Double?
    /// Photos' `ZHDRTYPE`: 0 for SDR, nonzero for HDR (see `PhotoItemBuilder`); nil when unknown.
    public var hdrType: Int?

    public init(fps: Double? = nil, codec: String? = nil, bitRate: Double? = nil, hdrType: Int? = nil) {
        self.fps = fps
        self.codec = codec
        self.bitRate = bitRate
        self.hdrType = hdrType
    }
}

/// How reading the index went.
public enum PhotosIndexStatus: Sendable, Equatable {
    case loaded(count: Int)
    /// The database couldn't be read for lack of permission (Full Disk Access not granted).
    case noAccess
    /// No library or no database at the expected place.
    case notFound
    /// The database is there but isn't in a shape this reader understands.
    case unreadable(String)
}

/// Reads frame rate, codec, bit rate and HDR type for every video from the Photos library's own database.
///
/// This is an unofficial source, so it is read with care: the database and its `-wal`/`-shm` files are copied to
/// a private temporary folder first and only that copy is opened, read-only. The real library is never opened or
/// written. Missing columns read as unknown; any failure returns no entries and a status instead of throwing.
public struct PhotosIndex: Sendable {
    public let libraryURL: URL

    public init(libraryURL: URL = PhotosIndex.defaultLibraryURL) {
        self.libraryURL = libraryURL
    }

    /// `~/Pictures/Photos Library.photoslibrary` in the user's real home folder.
    public static var defaultLibraryURL: URL {
        homeDirectory.appending(path: "Pictures/Photos Library.photoslibrary", directoryHint: .isDirectory)
    }

    /// The account's home folder from the user database, which stays right if the process has a container home.
    private static var homeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static let databaseName = "Photos.sqlite"

    /// Entries keyed by asset UUID (uppercase), or no entries and the reason.
    @concurrent
    public func load() async -> (entries: [String: PhotoIndexEntry], status: PhotosIndexStatus) {
        let source = libraryURL.appending(path: "database", directoryHint: .isDirectory)
        let snapshot: URL
        do {
            snapshot = try Self.makeSnapshot(of: source)
        } catch {
            return ([:], Self.status(for: error))
        }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        do {
            let database = try IndexDatabase(snapshot: snapshot)
            defer { database.close() }
            let entries = try database.videoEntries()
            return (entries, .loaded(count: entries.count))
        } catch let error as IndexError {
            return ([:], .unreadable(error.reason))
        } catch {
            return ([:], .unreadable(error.localizedDescription))
        }
    }

    // MARK: - Snapshot

    /// Copies the database and any `-wal`/`-shm` next to it into a new temporary folder; returns the copied database.
    /// The folder is on the library's volume when possible, so the copy is a cheap clone.
    private static func makeSnapshot(of databaseFolder: URL) throws -> URL {
        let files = FileManager.default
        let folder = temporaryFolder(near: databaseFolder)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let copy = folder.appending(path: databaseName)
            try files.copyItem(at: databaseFolder.appending(path: databaseName), to: copy)
            for suffix in ["-wal", "-shm"] {
                let name = databaseName + suffix
                let original = databaseFolder.appending(path: name)
                guard files.fileExists(atPath: original.path) else { continue }
                try files.copyItem(at: original, to: folder.appending(path: name))
            }
            return copy
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    /// A new, unique folder that only this load uses; it is removed with everything in it afterwards.
    private static func temporaryFolder(near databaseFolder: URL) -> URL {
        if let replacement = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: databaseFolder, create: true)
        {
            return replacement
        }
        return FileManager.default.temporaryDirectory.appending(
            path: "index-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Missing file → `.notFound`; permission denied (no Full Disk Access) → `.noAccess`; anything else → unreadable.
    static func status(for error: any Error) -> PhotosIndexStatus {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSPOSIXErrorDomain {
                switch Int32(nsError.code) {
                case ENOENT, ENOTDIR: return .notFound
                case EPERM, EACCES: return .noAccess
                default: break
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            case NSFileReadNoPermissionError: return .noAccess
            default: break
            }
        }
        return .unreadable(error.localizedDescription)
    }
}

// MARK: - Database

private struct IndexError: Error {
    let reason: String
}

/// A read-only connection to the private copy of the index.
private struct IndexDatabase {
    private let handle: OpaquePointer

    private static let videoKind = 1

    /// Opens the copy read-only. If that fails (the write-ahead log can need things a read-only open can't do),
    /// opens it as immutable instead, which skips the log.
    init(snapshot: URL) throws {
        if let handle = Self.open(snapshot.path, flags: SQLITE_OPEN_READONLY) {
            self.handle = handle
            return
        }
        var components = URLComponents(url: snapshot, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        let uri = components?.string ?? "file:\(snapshot.path)?mode=ro&immutable=1"
        if let handle = Self.open(uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) {
            self.handle = handle
            return
        }
        throw IndexError(reason: "The Photos database couldn't be opened.")
    }

    /// A connection that can read the schema, or nil.
    private static func open(_ path: String, flags: Int32) -> OpaquePointer? {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(path, &handle, flags, nil)
        guard let handle else { return nil }
        if opened == SQLITE_OK, sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK {
            return handle
        }
        sqlite3_close_v2(handle)
        return nil
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Column names of a table; empty when the table doesn't exist.
    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("PRAGMA table_info(\(table))") { row in
            if let name = row.text(1) { names.insert(name) }
        }
        return names
    }

    func videoEntries() throws -> [String: PhotoIndexEntry] {
        let assetColumns = try columns(of: "ZASSET")
        let attributeColumns = try columns(of: "ZEXTENDEDATTRIBUTES")
        guard !assetColumns.isEmpty else { throw IndexError(reason: "The ZASSET table is missing.") }
        guard !attributeColumns.isEmpty else { throw IndexError(reason: "The ZEXTENDEDATTRIBUTES table is missing.") }
        for column in ["Z_PK", "ZUUID"] where !assetColumns.contains(column) {
            throw IndexError(reason: "ZASSET has no \(column) column.")
        }
        guard attributeColumns.contains("ZASSET") else {
            throw IndexError(reason: "ZEXTENDEDATTRIBUTES has no ZASSET column.")
        }

        func attribute(_ name: String) -> String { attributeColumns.contains(name) ? "e.\(name)" : "NULL" }
        let hdrType = assetColumns.contains("ZHDRTYPE") ? "a.ZHDRTYPE" : "NULL"
        var conditions = ["a.ZUUID IS NOT NULL"]
        if assetColumns.contains("ZKIND") { conditions.append("a.ZKIND = \(Self.videoKind)") }
        if assetColumns.contains("ZTRASHEDSTATE") { conditions.append("a.ZTRASHEDSTATE = 0") }
        let sql = """
            SELECT a.ZUUID, \(attribute("ZFPS")), \(attribute("ZCODEC")), \(attribute("ZBITRATE")), \(hdrType)
            FROM ZASSET a LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK
            WHERE \(conditions.joined(separator: " AND "))
            """

        var entries: [String: PhotoIndexEntry] = [:]
        try query(sql) { row in
            guard let uuid = row.text(0)?.uppercased(), !uuid.isEmpty else { return }
            entries[uuid] = PhotoIndexEntry(
                fps: row.positiveDouble(1), codec: row.codec(2), bitRate: row.positiveDouble(3), hdrType: row.integer(4)
            )
        }
        return entries
    }

    private func query(_ sql: String, _ each: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError(reason: lastMessage)
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: each(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw IndexError(reason: lastMessage)
            }
        }
    }
}

/// The current row of a statement.
private struct Row {
    let statement: OpaquePointer

    private func type(_ column: Int32) -> Int32 { sqlite3_column_type(statement, column) }

    func text(_ column: Int32) -> String? {
        guard type(column) != SQLITE_NULL, let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    func integer(_ column: Int32) -> Int? {
        type(column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
    }

    /// A number above zero; zero and below mean unknown.
    func positiveDouble(_ column: Int32) -> Double? {
        guard type(column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, column)
        return value.isFinite && value > 0 ? value : nil
    }

    /// The codec as a four-character code. Photos may store it as text (`hvc1`) or as the code's integer value,
    /// which a text column keeps as a string of digits.
    func codec(_ column: Int32) -> String? {
        switch type(column) {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            return Self.fourCharacterCode(sqlite3_column_int64(statement, column))
        case SQLITE_TEXT:
            guard let value = text(column)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            if value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let number = Int64(value) {
                return Self.fourCharacterCode(number)
            }
            return value
        default:
            return nil
        }
    }

    /// `0x68766331` → `hvc1`; nil when the value isn't four printable ASCII characters.
    static func fourCharacterCode(_ value: Int64) -> String? {
        guard value > 0, value <= Int64(UInt32.max) else { return nil }
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
