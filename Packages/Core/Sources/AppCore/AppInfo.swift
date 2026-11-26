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
}
