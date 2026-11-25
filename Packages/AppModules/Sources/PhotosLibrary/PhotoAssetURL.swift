import Foundation

/// The address a queued Photos job carries as its source: `x-photos-asset:<percent-encoded local identifier>`.
///
/// It is not a file: nothing that builds a path (bookmarks, existence checks, Show in Finder) is handed one. The
/// queue only needs it to tell which video a job is for, so a video already in the queue isn't added twice.
public enum PhotoAssetURL {
    public static let scheme = "x-photos-asset"

    /// Local identifiers contain slashes (`<uuid>/L0/001`); they are encoded so the address stays opaque.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func url(for localIdentifier: String) -> URL {
        let encoded = localIdentifier.addingPercentEncoding(withAllowedCharacters: unreserved) ?? localIdentifier
        return URL(string: "\(scheme):\(encoded)") ?? URL(filePath: "/")
    }

    /// The local identifier an address stands for; nil for a file or any other address.
    public static func identifier(from url: URL) -> String? {
        let prefix = "\(scheme):"
        let text = url.absoluteString
        guard text.hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count)).removingPercentEncoding
    }
}
