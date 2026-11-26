import Foundation

/// A link in the Help menu.
public struct HelpLink: Equatable, Sendable {
    public let title: String
    public let url: URL
}

/// The Help menu's items, from the project's web address in the app's Info.plist (`AppHelpURL`, built from the
/// brand values). Help is the project's README online: there is no help book.
public enum HelpMenu {
    public static let infoKey = "AppHelpURL"

    /// Empty when the address is missing or isn't https, so the menu never shows an item that goes nowhere.
    public static func links(appName: String, homepage: String?) -> [HelpLink] {
        guard let homepage, var components = URLComponents(string: homepage), components.scheme == "https",
            components.host != nil
        else { return [] }
        components.fragment = nil
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        func link(_ title: String, path suffix: String = "", fragment: String? = nil) -> HelpLink? {
            var parts = components
            parts.path = path + suffix
            parts.fragment = fragment
            return parts.url.map { HelpLink(title: title, url: $0) }
        }
        return [
            link("\(appName) Help"),
            link("Privacy", fragment: "privacy"),
            link("Release Notes", path: "/blob/main/CHANGELOG.md"),
            link("Report an Issue…", path: "/issues"),
        ].compactMap { $0 }
    }
}
