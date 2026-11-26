import AppKit
import AppUI
import ImageIO
import LocalLibrary
import PhotosLibrary
import UniformTypeIdentifiers

/// What the library grids do beyond selecting: open, Share, Show in Photos, Quick Look for Photos, and the subtitle.
extension AppModel {
    // MARK: Local Files

    /// The files Share sends: the visible selection's files that exist.
    var shareURLs: [URL] { selectedItems.filter(\.isAvailable).compactMap(\.fileURL) }

    /// The files a tile's context menu sends.
    func shareURLs(clicked item: VideoItem) -> [URL] {
        contextTargets(clicked: item).filter(\.isAvailable).compactMap(\.fileURL)
    }

    /// Double-click and Return: opens the videos in their default app, as Finder does. A missing file beeps.
    func openLocal(_ ids: Set<UUID>) {
        let items = selectedItems.filter { ids.contains($0.id) }
        openLocal(items)
    }

    /// The context menu's Open: the selection when the clicked tile is part of it, else that tile.
    func openLocal(clicked item: VideoItem) {
        openLocal(contextTargets(clicked: item))
    }

    private func openLocal(_ items: [VideoItem]) {
        let urls = items.filter(\.isAvailable).compactMap(\.fileURL)
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        guard OpenLimit.allows(urls.count) else {
            alert = AppAlert(
                title: "Too Many Videos to Open",
                message: "Select up to \(OpenLimit.maximum) videos to open them at once.")
            return
        }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    // MARK: Videos (Photos)

    /// Double-click and Return on a Photos video: shows it in Photos. Nothing in Photos changes.
    func showInPhotos(_ ids: Set<UUID>) {
        guard let item = selectedPhotoItems.first(where: { ids.contains($0.id) }) else { return }
        showInPhotos(item)
    }

    func showInPhotos(_ item: VideoItem) {
        if let identifier = item.photosIdentifier, let url = PhotosDeepLink.assetURL(localIdentifier: identifier),
            NSWorkspace.shared.open(url)
        {
            return
        }
        // The address didn't open: at least bring Photos forward.
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Space on the Videos page: Quick Look of the selected video's poster frame (the thumbnail Photos has on this
    /// Mac). The video itself stays in Photos, so nothing is downloaded or exported.
    func quickLookPhotoPoster() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let item = selectedPhotoItems.first else { return }
        quickLookPhotoPoster(of: item)
    }

    func quickLookPhotoPoster(of item: VideoItem) {
        if !selectedPhotoItems.contains(where: { $0.id == item.id }) { photosBrowser.selection = [item.id] }
        let source = thumbnailSource
        Task {
            guard let image = await source.image(for: item, maxPixel: 1600),
                let url = PosterFile.write(image, named: item.name)
            else {
                NSSound.beep()
                return
            }
            quickLookURL = url
        }
    }

    // MARK: Subtitle

    /// "218 of 1,203 videos · 29.8 GB · 3 selected, 1.2 GB": the window subtitle for a library page.
    func subtitle(for browser: LibraryBrowser, total: Int, selected: [VideoItem], activity: String?) -> String {
        let snapshot = browser.snapshot
        return LibrarySubtitle.text(
            shownCount: snapshot.items.count, shownBytes: snapshot.totalBytes, totalCount: total,
            selectedCount: selected.count, selectedBytes: selected.reduce(0) { $0 + $1.byteSize }, activity: activity)
    }
}

/// A poster frame written for Quick Look, in a folder of the app's own under the temporary directory. The previous
/// poster is replaced; the system clears the folder.
enum PosterFile {
    static func write(_ image: CGImage, named name: String) -> URL? {
        // Named after the app's own identifier, so removing it can only remove what this app wrote.
        let id = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let folder = FileManager.default.temporaryDirectory
            .appending(path: id, directoryHint: .isDirectory)
            .appending(path: "QuickLookPosters", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let base = URL(filePath: name).deletingPathExtension().lastPathComponent.replacing("/", with: "-")
        let url = folder.appending(path: "\(base.isEmpty ? "Video" : base) Poster Frame.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}
