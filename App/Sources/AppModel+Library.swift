import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary

extension AppModel {
    /// The media-type filter when the sidebar points at one.
    var badgeFilter: MediaBadge? {
        if case .mediaType(let badge) = selection { return badge }
        return nil
    }

    /// The grid's sections: the library grouped, sorted, filtered by media type and by the search text.
    var sections: [MediaSection<LibraryItem>] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return library.groups(by: grouping, sort: sort, filter: badgeFilter).compactMap { group in
            let items =
                query.isEmpty
                ? group.items : group.items.filter { $0.url.lastPathComponent.localizedStandardContains(query) }
            guard !items.isEmpty else { return nil }
            let count = items.count == 1 ? "1 video" : "\(items.count) videos"
            return MediaSection(
                id: group.id, title: grouping == .none ? "" : group.title, subtitle: count, items: items)
        }
    }

    var shownItems: [LibraryItem] { sections.flatMap(\.items) }

    var selectedItems: [LibraryItem] { library.items.filter { selectedItemIDs.contains($0.id) } }

    /// What converting the given items with the current preset would free; Kept As Is items count as zero.
    func couldFreeBytes(for items: [LibraryItem]) -> Int64 {
        SavingsCalculator.couldFreeBytes(for: items.map(\.savingsSource), preset: preset)
    }

    /// Space toggles Quick Look for the selection.
    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            quickLookURL = shownItems.first { selectedItemIDs.contains($0.id) }?.url
        }
    }

    var quickLookURLs: [URL] { shownItems.filter { selectedItemIDs.contains($0.id) }.map(\.url) }
}

extension LibraryItem {
    var savingsSource: SavingsCalculator.Source { (byteSize: byteSize, inventory: inventory) }
}
