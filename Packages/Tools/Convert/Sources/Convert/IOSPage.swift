/// The pages of the video tool on iOS: what its page list shows below the Tools list. They map onto the shared
/// `VideoPage`s the model navigates with; Kept as Is and Failed live in Completed, and a media-type filter shows Files.
public enum IOSPage: String, CaseIterable, Hashable, Sendable, Identifiable {
    case overview
    case photos
    case files
    case queue
    case completed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .photos: "Photos"
        case .files: "Files"
        case .queue: "Queue"
        case .completed: "Completed"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .queue: "list.bullet.rectangle"
        case .completed: "checkmark.circle"
        }
    }

    /// The page the model shows for this one.
    public var videoPage: VideoPage {
        switch self {
        case .overview: .overview
        case .photos: .photosVideos
        case .files: .localFiles
        case .queue: .queue
        case .completed: .completed
        }
    }

    /// The page that shows a model page, or nil for a page iOS doesn't list.
    public init?(_ page: VideoPage?) {
        switch page {
        case .overview: self = .overview
        case .photosVideos: self = .photos
        case .localFiles, .mediaType: self = .files
        case .queue: self = .queue
        case .completed, .keptAsIs, .failed: self = .completed
        case .tool, nil: return nil
        }
    }
}
