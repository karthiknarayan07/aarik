#if os(iOS)
    import UIKit

    /// Files can't select an item from another app, so `reveal` opens the item's folder in Files (`shareddocuments:`).
    @MainActor
    public final class IOSFileRevealer: FileRevealer {
        public init() {}

        public func reveal(_ urls: [URL]) {
            guard let first = urls.first else { return }
            let folder = first.deletingLastPathComponent()
            guard var components = URLComponents(url: folder, resolvingAgainstBaseURL: false) else { return }
            components.scheme = "shareddocuments"
            guard let url = components.url else { return }
            UIApplication.shared.open(url)
        }

        public func open(_ url: URL) {
            UIApplication.shared.open(url)
        }
    }
#endif
