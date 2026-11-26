import Foundation
import LocalLibrary
import PhotosLibrary

/// The shared library service: Files and Photos browsing, and the thumbnails for both. It never downloads to browse:
/// Photos items come from the local index and the thumbnails Photos already has. A tool asks it for the media it
/// handles and adds its own badges, filters and grouping on top (`LibraryBrowser` is per tool).
@MainActor
public final class LibraryService {
    /// The files the user added: folders and videos, with their availability and metadata.
    public let local: LocalLibrary
    /// The user's Photos videos, loaded when a tool first asks (never at launch).
    public let photos: PhotosLibrary
    public let photoStore: any PhotoStore
    public let thumbnails: ThumbnailCache
    public let thumbnailSource: ThumbnailSource

    /// `directory` is where the local library keeps its list of added files.
    public init(directory: URL, photoStore: any PhotoStore, thumbnails: ThumbnailCache = ThumbnailCache()) {
        self.local = LocalLibrary(directory: directory)
        self.photos = PhotosLibrary(store: photoStore)
        self.photoStore = photoStore
        self.thumbnails = thumbnails
        self.thumbnailSource = ThumbnailSource(cache: thumbnails, photos: photoStore)
    }
}
