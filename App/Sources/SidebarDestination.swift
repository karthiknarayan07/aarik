import AppUI
import LocalLibrary

/// Where the sidebar points.
enum SidebarDestination: Hashable, Sendable {
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
    var showsLibrary: Bool {
        switch self {
        case .localFiles, .mediaType: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .photosVideos: "Videos"
        case .localFiles: "Local Files"
        case .mediaType(let badge): badge.displayName
        case .tool(let id): ToolRegistry.tool(withID: id)?.title ?? "Tool"
        case .queue: "Queue"
        case .completed: "Completed"
        case .keptAsIs: "Kept as Is"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "chart.pie"
        case .photosVideos: "photo.on.rectangle"
        case .localFiles: "folder"
        case .mediaType(let badge): badge.systemImage
        case .tool(let id): ToolRegistry.tool(withID: id)?.systemImage ?? "wrench.and.screwdriver"
        case .queue: "list.bullet.rectangle"
        case .completed: "checkmark.circle"
        case .keptAsIs: "equal.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// Placeholder content for the destinations that don't have a screen yet.
    @MainActor var emptyState: EmptyState {
        switch self {
        case .overview:
            EmptyState(
                "Coming with Photos", systemImage: systemImage,
                message: "A summary of the space you could free arrives with Photos library support.")
        case .photosVideos:
            EmptyState(
                "Videos", systemImage: systemImage,
                message: "Videos from your Photos library appear here.")
        case .localFiles, .mediaType:
            EmptyState(
                "No Files Added", systemImage: systemImage,
                message: "Add videos or folders to see how much space \(AppModel.displayName) could free.")
        case .tool:
            EmptyState(
                title, systemImage: systemImage, message: "Choose videos in Local Files, then add them to the queue.")
        case .queue:
            EmptyState(
                "Queue Is Empty", systemImage: systemImage,
                message: "Videos you add to the queue are converted one at a time.")
        case .completed:
            EmptyState(
                "Nothing Completed Yet", systemImage: systemImage,
                message: "Finished conversions and the space they saved appear here.")
        case .keptAsIs:
            EmptyState(
                "Nothing Kept as Is", systemImage: systemImage,
                message: "Videos that wouldn't get meaningfully smaller are listed here with the reason.")
        case .failed:
            EmptyState(
                "No Failures", systemImage: systemImage,
                message: "Conversions that couldn't finish appear here with the reason and a way to retry.")
        }
    }
}
