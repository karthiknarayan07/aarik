import Foundation

/// What the Overview shows, kept between launches so the page can draw it at once and refresh behind it: the size of
/// each library now and what converting would free, the biggest groups, what finished conversions saved, and that saving
/// by day. Plain values; the tool decides what the libraries and groups are.
public struct SavingsSnapshot: Codable, Sendable, Equatable {
    /// Bumped when the stored shape changes; a snapshot of another version is dropped, not read.
    public static let currentVersion = 1

    public struct Library: Codable, Sendable, Equatable {
        public var name: String
        public var count: Int
        public var bytes: Int64
        public var couldFree: Int64

        public init(name: String, count: Int, bytes: Int64, couldFree: Int64) {
            self.name = name
            self.count = count
            self.bytes = bytes
            self.couldFree = couldFree
        }
    }

    public struct Group: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var bytes: Int64

        public init(id: String, title: String, bytes: Int64) {
            self.id = id
            self.title = title
            self.bytes = bytes
        }
    }

    /// Videos converted on one day, and what they freed.
    public struct Day: Codable, Sendable, Equatable {
        public var day: Date
        public var videos: Int
        public var savedBytes: Int64

        public init(day: Date, videos: Int, savedBytes: Int64) {
            self.day = day
            self.videos = videos
            self.savedBytes = savedBytes
        }
    }

    public var version: Int
    public var updatedAt: Date
    public var libraries: [Library]
    public var groups: [Group]
    public var days: [Day]
    /// Bytes freed by finished conversions.
    public var savedBytes: Int64
    public var conversions: Int

    public init(
        updatedAt: Date = AppClock.now, libraries: [Library] = [], groups: [Group] = [], days: [Day] = [],
        savedBytes: Int64 = 0, conversions: Int = 0
    ) {
        self.version = Self.currentVersion
        self.updatedAt = updatedAt
        self.libraries = libraries
        self.groups = groups
        self.days = days
        self.savedBytes = savedBytes
        self.conversions = conversions
    }

    public var couldFree: Int64 { libraries.reduce(0) { $0 + $1.couldFree } }
    public var totalBytes: Int64 { libraries.reduce(0) { $0 + $1.bytes } }
}
