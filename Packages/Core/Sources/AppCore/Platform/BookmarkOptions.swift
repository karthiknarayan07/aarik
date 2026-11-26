import Foundation

/// Bookmark options that differ by platform. Mac sandboxed apps need `.withSecurityScope`; on iOS every bookmark
/// to a user-chosen location is already security scoped and the option doesn't exist.
public enum PlatformBookmark {
    public static var creation: URL.BookmarkCreationOptions {
        #if os(macOS)
            [.withSecurityScope]
        #else
            []
        #endif
    }

    /// The options to try first when resolving, then fall back to `fallbackResolution`.
    public static var resolution: URL.BookmarkResolutionOptions {
        #if os(macOS)
            [.withSecurityScope, .withoutMounting, .withoutUI]
        #else
            [.withoutMounting]
        #endif
    }

    public static var fallbackResolution: URL.BookmarkResolutionOptions {
        #if os(macOS)
            [.withoutMounting, .withoutUI]
        #else
            [.withoutMounting]
        #endif
    }
}
