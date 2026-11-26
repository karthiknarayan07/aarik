#if os(iOS)
    import Convert
    import SwiftUI

    extension IOSPage {
        /// The page's symbol color: system colors only, like the Health and Settings sidebars.
        var tint: Color {
            switch self {
            case .overview: .indigo
            case .photos: .pink
            case .files: .blue
            case .queue: .orange
            case .completed: .green
            }
        }
    }
#endif
