import Foundation

/// The address that shows a video in the Photos app. Opening it is the only thing the app does with it; nothing in
/// the library changes.
public enum PhotosDeepLink {
    /// `photos://asset?uuid=<uuid>`, from a local identifier (`<uuid>/L0/001`); nil when the identifier doesn't start
    /// with a UUID.
    public static func assetURL(localIdentifier: String) -> URL? {
        let uuid = localIdentifier.prefix { $0 != "/" }
        guard UUID(uuidString: String(uuid)) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "photos"
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "uuid", value: String(uuid))]
        return components.url
    }
}
