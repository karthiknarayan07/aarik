import Foundation

/// Shows a file to the user: "Show in Finder" on the Mac, the Files app on iOS, and opens it in its default app.
/// Adapters: `MacFileRevealer` and `IOSFileRevealer`. Tests use `FakeFileRevealer` (MediaTestSupport).
@MainActor
public protocol FileRevealer: AnyObject {
    /// Selects the items in their enclosing folder where the platform can; otherwise opens the folder.
    func reveal(_ urls: [URL])
    /// Opens the item in its default app.
    func open(_ url: URL)
}
