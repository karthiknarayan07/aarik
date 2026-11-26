import AppCore
import Assistant
import Foundation
import LocalLibrary

extension ConvertModel {
    /// Opens the library page the group belongs to and shows the group's videos there, as search tokens the user
    /// can remove. Works the same with or without the model: no model is involved. Whatever search or filters the
    /// page had are replaced, and nothing is selected.
    public func show(_ bucket: SavingsBucket) {
        // A row may be a refresh behind: act on the group as it is now, and on nothing if it is gone.
        guard let bucket = assistant.smartPicks.current(bucket) else { return }
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
    public func canAddToQueue(_ bucket: SavingsBucket) -> Bool {
        guard let bucket = assistant.smartPicks.current(bucket), !bucket.itemIDs.isEmpty else { return false }
        return bucket.library == .photos
            ? photosSaveLocation.destination != nil : saveLocation.destination != nil
    }

    /// Shows the group, selects its videos and goes through the same steps as Add to Queue on that page: the
    /// Replace confirmation, the loss sheet for videos that would lose something, then the queue. The model never
    /// queues anything itself; this runs only when the user presses the button.
    public func addToQueue(_ bucket: SavingsBucket) {
        guard canAddToQueue(bucket), let bucket = assistant.smartPicks.current(bucket) else { return }
        // The group's ids are as of the last refresh: take only the videos that are still there and available.
        let page = bucket.library == .photos ? photosBrowser : browser
        let ids = bucket.availableItemIDs(in: page.collection.items)
        guard !ids.isEmpty else { return }
        show(bucket)
        page.selection = Set(ids)
        requestAddSelectionToQueue()
    }
}

extension ConvertModel {
    /// The Local Files items that already have a finished conversion, or are one: "not yet shrunk" hides them.
    public func shrunkIDs(in browser: LibraryBrowser) -> Set<UUID> {
        var paths = Set<String>()
        for job in jobs {
            guard case .completed(let outcome) = job.state else { continue }
            paths.insert(job.sourceUsed.standardizedFileURL.path)
            paths.insert(job.source.standardizedFileURL.path)
            paths.insert(outcome.output.standardizedFileURL.path)
        }
        guard !paths.isEmpty else { return [] }
        return Set(
            browser.collection.items.compactMap { item in
                item.fileURL.flatMap { paths.contains($0.standardizedFileURL.path) ? item.id : nil }
            })
    }
}
