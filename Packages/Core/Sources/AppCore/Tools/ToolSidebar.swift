import Foundation

/// One row of a tool's sidebar. The shell draws the rows; the tool says what they are.
public struct ToolSidebarItem<Destination: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public enum Availability: Hashable, Sendable {
        case available
        /// Shown disabled and not selectable.
        case comingSoon
    }

    public let id: String
    /// Nil for a row that can't be selected.
    public let destination: Destination?
    public let title: String
    public let systemImage: String
    /// A badge number; nil shows none.
    public let count: Int?
    /// A running job's progress, from 0 to 1; shows a small ring.
    public let progress: Double?
    public let availability: Availability

    public init(
        id: String, destination: Destination?, title: String, systemImage: String, count: Int? = nil,
        progress: Double? = nil, availability: Availability = .available
    ) {
        self.id = id
        self.destination = destination
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.progress = progress
        self.availability = availability
    }

    /// What VoiceOver reads for the row: its title.
    public var accessibilityLabel: String { title }

    /// What VoiceOver reads after the title: the count and the running progress, or that the tool is coming soon.
    public var accessibilityValue: String {
        if availability == .comingSoon { return "coming soon" }
        var parts: [String] = []
        if let count { parts.append("\(count)") }
        if let progress { parts.append("converting \(Int((progress * 100).rounded()))%") }
        return parts.joined(separator: ", ")
    }
}

/// A titled group of sidebar rows.
public struct ToolSidebarSection<Destination: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public let title: String
    public let items: [ToolSidebarItem<Destination>]
    public var id: String { title }

    public init(title: String, items: [ToolSidebarItem<Destination>]) {
        self.title = title
        self.items = items
    }
}

/// What the shell draws for a sidebar: one row per item, and which rows can be selected. The shell asks this type, so
/// the decisions are testable without a window.
public struct ToolSidebarModel<Destination: Hashable & Sendable>: Equatable {
    public struct Row: Identifiable, Equatable {
        public let item: ToolSidebarItem<Destination>
        public var id: String { item.id }
        /// The value the row selects; nil for a row that can't be selected.
        public var tag: Destination? { isSelectable ? item.destination : nil }
        public var isSelectable: Bool { item.availability == .available && item.destination != nil }
    }

    public struct Section: Identifiable, Equatable {
        public let title: String
        public let rows: [Row]
        public var id: String { title }
    }

    public let sections: [Section]

    public init(_ sections: [ToolSidebarSection<Destination>]) {
        self.sections = sections.map { section in
            Section(title: section.title, rows: section.items.map(Row.init(item:)))
        }
    }

    /// Every page the sidebar can select, in order.
    public var selectableDestinations: [Destination] {
        sections.flatMap(\.rows).compactMap(\.tag)
    }

    /// Whether a click may change the selection to this: a listed, enabled row, or nothing.
    public func accepts(_ destination: Destination?) -> Bool {
        destination.map(selectableDestinations.contains) ?? true
    }
}
