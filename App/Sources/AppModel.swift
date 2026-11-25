import Foundation
import Observation

/// Where the sidebar points. Media-type filters join once the library can count them.
enum SidebarDestination: Hashable, Sendable {
    case overview
    case photosVideos
    case localFiles
    case tool(String)
    case queue
    case completed
    case keptAsIs
    case failed
}

/// The composition root: app-wide state shared by the window's views.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarDestination? = .localFiles
    var isInspectorPresented = true

    let tools: [ToolEntry] = ToolRegistry.tools
    let comingSoonTools: [ToolEntry] = ToolRegistry.comingSoon

    /// The user-facing app name, read from the bundle so the brand never appears in code.
    nonisolated static var displayName: String {
        let info = Bundle.main
        return info.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? info.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }
}
