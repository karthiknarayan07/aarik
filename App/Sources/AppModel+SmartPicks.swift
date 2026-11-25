import Assistant
import DownscaleVideo
import Foundation
import LocalLibrary

extension AppModel {
    /// Opens the library page the group belongs to and shows the group's videos there, as search tokens the user
    /// can remove. Works the same with or without the model: no model is involved. Whatever search or filters the
    /// page had are replaced, and nothing is selected.
    func show(_ bucket: SavingsBucket) {
        let isPhotos = bucket.library == .photos
        let page = isPhotos ? photosBrowser : browser
        let search = isPhotos ? assistant.photosSearch : assistant.localSearch
        selection = isPhotos ? .photosVideos : .localFiles
        page.selection = []
        // Photos videos have no finished conversions to leave out; the group's filters say so for Local Files only.
        search.show(
            bucket.filters(), browser: page, sidebarBadge: nil, shrunkIDs: isPhotos ? [] : shrunkIDs(in: browser))
    }

    /// Whether "Add These to the Queue" can run: the page it adds from has somewhere to save the copies.
    func canAddToQueue(_ bucket: SavingsBucket) -> Bool {
        guard !bucket.itemIDs.isEmpty else { return false }
        return bucket.library == .photos
            ? photosSaveLocation.destination != nil : saveLocation.destination != nil
    }

    /// Shows the group, selects its videos and goes through the same steps as Add to Queue on that page: the
    /// Replace confirmation, the loss sheet for videos that would lose something, then the queue. The model never
    /// queues anything itself; this runs only when the user presses the button.
    func addToQueue(_ bucket: SavingsBucket) {
        guard canAddToQueue(bucket) else { return }
        show(bucket)
        (bucket.library == .photos ? photosBrowser : browser).selection = Set(bucket.itemIDs)
        requestAddSelectionToQueue()
    }
}
