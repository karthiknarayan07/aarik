import AppCore
import LocalLibrary

/// The pages of the video tool: what its sidebar selects.
public enum VideoPage: Hashable, Sendable {
    case overview
    case photosVideos
    case localFiles
    case mediaType(MediaBadge)
    case tool(String)
    case queue
    case completed
    case keptAsIs
    case failed

    /// Local Files and the media-type filters share the grid.
    public var showsLibrary: Bool {
        switch self {
        case .localFiles, .mediaType: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .photosVideos: "Videos"
        case .localFiles: "Local Files"
        case .mediaType(let badge): badge.displayName
        case .tool(let id): VideoSidebar.tool(withID: id)?.name ?? "Tool"
        case .queue: "Queue"
        case .completed: "Completed"
        case .keptAsIs: "Kept as Is"
        case .failed: "Failed"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "chart.pie"
        case .photosVideos: "photo.on.rectangle"
        case .localFiles: "folder"
        case .mediaType(let badge): badge.systemImage
        case .tool(let id): VideoSidebar.tool(withID: id)?.symbol ?? "wrench.and.screwdriver"
        case .queue: "list.bullet.rectangle"
        case .completed: "checkmark.circle"
        case .keptAsIs: "equal.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// What the sidebar needs to know to list the video tool's pages.
public struct VideoSidebarState: Sendable, Equatable {
    /// The Photos videos; nil until they have loaded.
    public var photosCount: Int?
    public var localCount: Int
    /// How many Local Files items carry each badge.
    public var badgeCounts: [MediaBadge: Int]
    public var activity: ActivitySummary

    public init(photosCount: Int?, localCount: Int, badgeCounts: [MediaBadge: Int], activity: ActivitySummary) {
        self.photosCount = photosCount
        self.localCount = localCount
        self.badgeCounts = badgeCounts
        self.activity = activity
    }
}

/// The video tool's sidebar: Library, Media types (only the types present), Tools and Activity.
public enum VideoSidebar {
    public static let tools: [ToolDescriptor] = [DownscaleTool.descriptor]

    /// Shown disabled with a "Soon" label until they ship.
    public static let comingSoon: [ToolDescriptor] = [
        ToolDescriptor(id: "convert-image", name: "Convert Image", symbol: "photo", category: .image),
        ToolDescriptor(id: "pdf-tools", name: "PDF Tools", symbol: "doc.richtext", category: .pdf),
    ]

    public static func tool(withID id: String) -> ToolDescriptor? {
        tools.first { $0.id == id }
    }

    public static func sections(_ state: VideoSidebarState) -> [ToolSidebarSection<VideoPage>] {
        var sections = [
            ToolSidebarSection(
                title: "Library",
                items: [
                    item(.overview),
                    item(.photosVideos, count: state.photosCount),
                    item(.localFiles, count: state.localCount),
                ])
        ]
        let badges = MediaBadge.allCases.filter { state.badgeCounts[$0] != nil }
        if !badges.isEmpty {
            sections.append(
                ToolSidebarSection(
                    title: "Media Types",
                    items: badges.map { item(.mediaType($0), count: state.badgeCounts[$0] ?? 0) }))
        }
        sections.append(
            ToolSidebarSection(
                title: "Tools",
                items: tools.map { item(.tool($0.id)) }
                    + comingSoon.map {
                        ToolSidebarItem(
                            id: $0.id, destination: nil, title: $0.name, systemImage: $0.symbol,
                            availability: .comingSoon)
                    }))
        let activity = state.activity
        sections.append(
            ToolSidebarSection(
                title: "Activity",
                items: [
                    item(.queue, count: activity.queue, progress: activity.runningProgress),
                    item(.completed, count: activity.completed),
                    item(.keptAsIs, count: activity.keptAsIs),
                    item(.failed, count: activity.failed),
                ]))
        return sections
    }

    private static func item(_ page: VideoPage, count: Int? = nil, progress: Double? = nil)
        -> ToolSidebarItem<VideoPage>
    {
        ToolSidebarItem(
            id: "\(page)", destination: page, title: page.title, systemImage: page.systemImage, count: count,
            progress: progress)
    }
}
