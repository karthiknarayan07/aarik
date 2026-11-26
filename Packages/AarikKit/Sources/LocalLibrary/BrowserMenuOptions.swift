import Foundation

/// How View → Group By and Sort By name and order their choices, as Finder's menus do (None first).
extension Grouping {
    public static let menuOrder: [Grouping] = [.none, .year, .month]

    public var menuTitle: String {
        switch self {
        case .none: "None"
        case .year: "Year"
        case .month: "Month"
        }
    }
}

extension Sort {
    public static let menuOrder: [Sort] = [.biggestFirst, .newestFirst]

    public var menuTitle: String {
        switch self {
        case .biggestFirst: "Biggest First"
        case .newestFirst: "Newest First"
        }
    }
}

/// Library items taken out of the library, kept so Undo can put them back. Only the items' files are remembered:
/// the files themselves are never touched, and adding them again scans them as new items.
public struct LibraryRemoval: Equatable, Sendable {
    public static let actionName = "Remove from Library"

    /// The removed items' files, in the order removed. Items without a file (none today) can't come back.
    public let urls: [URL]

    public init(items: [LibraryItem]) {
        urls = items.compactMap(\.fileURL)
    }

    public var isEmpty: Bool { urls.isEmpty }

    /// The items in `library` that are these files again, for Redo after an Undo.
    public func ids(in library: [LibraryItem]) -> Set<UUID> {
        let removed = Set(urls)
        return Set(library.filter { $0.fileURL.map(removed.contains) ?? false }.map(\.id))
    }
}
