#if os(iOS)
    import AppCore
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

    extension ConvertModel {
        /// The route to one of the tool's pages, for the shell's router.
        func route(to page: IOSPage) -> ToolRoute {
            ToolRoute(toolID: tool.id, page: page.rawValue)
        }

        /// The route to the page the model is on (after it was told to show a group), else Files.
        func routeToSelection() -> ToolRoute {
            route(to: IOSPage(selection) ?? .files)
        }
    }
#endif
