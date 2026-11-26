import SharedUI
import Convert

/// Where the sidebar points: the video tool's pages.
typealias SidebarDestination = VideoPage

extension VideoPage {
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
