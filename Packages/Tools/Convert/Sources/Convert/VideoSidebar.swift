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
    /// The assistant chat (shown only while Apple Intelligence is available).
    case ask

    /// Local Files and the media-type filters share the grid.
    public var showsLibrary: Bool {
        switch self {
        case .localFiles, .mediaType: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .overview: "Home"
        case .photosVideos: "Photos"
        case .localFiles: "Local Files"
        case .mediaType(let badge): badge.displayName
        case .tool(let id): VideoSidebar.tool(withID: id)?.name ?? "Tool"
        case .queue: "Queue"
        case .completed: "Completed"
        case .keptAsIs: "Kept as Is"
        case .failed: "Failed"
        case .ask: "Ask"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "house"
        case .photosVideos: "photo.on.rectangle"
        case .localFiles: "folder"
        case .mediaType(let badge): badge.systemImage
        case .tool(let id): VideoSidebar.tool(withID: id)?.symbol ?? "wrench.and.screwdriver"
        case .queue: "list.bullet.rectangle"
        case .completed: "checkmark.circle"
        case .keptAsIs: "equal.circle"
        case .failed: "exclamationmark.triangle"
        case .ask: "sparkles"
        }
    }

    /// The page as stored for the next launch; nil for pages that are not restored (a filter or a tool page).
    public var persistenceKey: String? {
        switch self {
        case .overview: "home"
        case .photosVideos: "photos"
        case .localFiles: "localFiles"
        case .queue: "queue"
        case .completed: "completed"
        case .keptAsIs: "keptAsIs"
        case .failed: "failed"
        case .ask: "ask"
        case .mediaType, .tool: nil
        }
    }

    public init?(persistenceKey: String) {
        let restorable: [VideoPage] = [
            .overview, .photosVideos, .localFiles, .queue, .completed, .keptAsIs, .failed, .ask,
        ]
        guard let page = restorable.first(where: { $0.persistenceKey == persistenceKey }) else { return nil }
        self = page
    }

    /// The colour of the page's sidebar symbol.
    public var tint: SidebarTint {
        switch self {
        case .overview: .blue
        case .photosVideos: .blue
        case .localFiles: .teal
        case .mediaType: .pink
        case .tool: .purple
        case .queue: .orange
        case .completed: .green
        case .keptAsIs: .gray
        case .failed: .red
        case .ask: .purple
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

/// The video tool's own pages, listed under its row in the shell's Tools section: Library, Media Types (only the
/// types present) and Activity. Home (`.overview`) and Ask are the shell's and are not listed.
public enum VideoSidebar {
    public static let tools: [ToolDescriptor] = [ConvertTool.descriptor]

    public static func tool(withID id: String) -> ToolDescriptor? {
        tools.first { $0.id == id }
    }

    public static func sections(_ state: VideoSidebarState) -> [ToolSidebarSection<VideoPage>] {
        var sections = [
            ToolSidebarSection(
                title: "Library",
                items: [
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
            id: "\(page)", destination: page, title: page.title, systemImage: page.systemImage, tint: page.tint,
            count: count,
            progress: progress)
    }
}
