import AppUI
import DownscaleVideo

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
                "No files added", systemImage: systemImage,
                message: "Add videos or folders to see how much space \(AppModel.displayName) could free.")
        case .tool:
            EmptyState(
                title, systemImage: systemImage, message: "Choose videos in Local files, then add them to the queue.")
        case .queue:
            EmptyState(
                "Queue is empty", systemImage: systemImage,
                message: "Videos you add to the queue are converted one at a time.")
        case .completed:
            EmptyState(
                "Nothing completed yet", systemImage: systemImage,
                message: "Finished conversions and the space they saved appear here.")
        case .keptAsIs:
            EmptyState(
                "Nothing kept as is", systemImage: systemImage,
                message: "Videos that wouldn't get meaningfully smaller are listed here with the reason.")
        case .failed:
            EmptyState(
                "No failures", systemImage: systemImage,
                message: "Conversions that couldn't finish appear here with the reason and a way to retry.")
        }
    }
}
