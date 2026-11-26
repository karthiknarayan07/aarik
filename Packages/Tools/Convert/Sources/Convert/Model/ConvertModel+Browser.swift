import AppCore
import AppUI
import ImageIO
import LocalLibrary
import PhotosLibrary
import UniformTypeIdentifiers

/// What the library grids do beyond selecting: open, Share, Show in Photos, Quick Look for Photos, and the subtitle.
extension ConvertModel {
    // MARK: Local Files

    /// The files Share sends: the visible selection's files that exist.
    public var shareURLs: [URL] { selectedItems.filter(\.isAvailable).compactMap(\.fileURL) }

    /// The files a tile's context menu sends.
    public func shareURLs(clicked item: LibraryItem) -> [URL] {
        contextTargets(clicked: item).filter(\.isAvailable).compactMap(\.fileURL)
    }

    /// Double-click and Return: opens the videos in their default app, as Finder does. A missing file beeps.
    public func openLocal(_ ids: Set<UUID>) {
        let items = selectedItems.filter { ids.contains($0.id) }
        openLocal(items)
    }

    /// The context menu's Open: the selection when the clicked tile is part of it, else that tile.
    public func openLocal(clicked item: LibraryItem) {
        openLocal(contextTargets(clicked: item))
    }

    private func openLocal(_ items: [LibraryItem]) {
        let urls = items.filter(\.isAvailable).compactMap(\.fileURL)
        guard !urls.isEmpty else {
            host.beep()
            return
        }
        guard OpenLimit.allows(urls.count) else {
            alert = AppAlert(
                title: "Too Many Videos to Open",
                message: "Select up to \(OpenLimit.maximum) videos to open them at once.")
            return
        }
        host.open(urls)
    }

    // MARK: Videos (Photos)

    /// Double-click and Return on a Photos video: shows it in Photos. Nothing in Photos changes.
    public func showInPhotos(_ ids: Set<UUID>) {
        guard let item = selectedPhotoItems.first(where: { ids.contains($0.id) }) else { return }
        showInPhotos(item)
    }

    public func showInPhotos(_ item: LibraryItem) {
        guard let identifier = item.photosIdentifier else { return }
        host.showInPhotos(identifier)
    }

    /// Space on the Videos page: Quick Look of the selected video's poster frame (the thumbnail Photos has on this
    /// Mac). The video itself stays in Photos, so nothing is downloaded or exported.
    public func quickLookPhotoPoster() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let item = selectedPhotoItems.first else { return }
        quickLookPhotoPoster(of: item)
    }

    public func quickLookPhotoPoster(of item: LibraryItem) {
        if !selectedPhotoItems.contains(where: { $0.id == item.id }) { photosBrowser.selection = [item.id] }
        let source = thumbnailSource
        let name = item.name
        Task {
            guard let image = await source.image(for: item, maxPixel: 1600) else {
                host.beep()
                return
            }
            let write = Task.detached(priority: .userInitiated) { PosterFile.write(image, named: name) }
            guard let url = await write.value else {
                host.beep()
                return
            }
            quickLookURL = url
        }
    }

    // MARK: Subtitle

    /// "218 of 1,203 videos · 29.8 GB · 3 selected, 1.2 GB": the window subtitle for a library page.
    public func subtitle(for browser: LibraryBrowser, total: Int, selected: [LibraryItem], activity: String?) -> String
    {
        let snapshot = browser.snapshot
        return LibrarySubtitle.text(
            shownCount: snapshot.items.count, shownBytes: snapshot.totalBytes, totalCount: total,
            selectedCount: selected.count, selectedBytes: selected.reduce(0) { $0 + $1.byteSize }, activity: activity)
    }
}

/// A poster frame written for Quick Look, in a folder of the app's own under the temporary directory. The previous
/// poster is replaced; the system clears the folder.
public enum PosterFile {
    public static func write(_ image: CGImage, named name: String) -> URL? {
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
