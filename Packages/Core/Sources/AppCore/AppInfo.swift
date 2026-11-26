import Foundation

/// What the running app calls itself. The name comes from the bundle (set from `Config/Brand.xcconfig`), so the brand
/// never appears in code.
public enum AppInfo {
    /// The user-facing app name.
    public static var displayName: String {
        displayName(in: .main)
    }

    public static func displayName(in bundle: Bundle) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// The App Group identifier configured in `bundle`'s `AppGroupIdentifier` Info.plist key, if set.
    public static func appGroupIdentifier(in bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
