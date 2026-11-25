import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary
import MediaEngine

extension AppModel {
    /// The media-type filter when the sidebar points at one.
    var badgeFilter: MediaBadge? {
        if case .mediaType(let badge) = selection { return badge }
        return nil
    }

    /// The grid's sections, built once per change of the library or the query (never per selection change).
    var sections: [MediaSection<LibraryItem>] {
        let grouping = browser.grouping
        return browser.cached("sections") { snapshot in
            snapshot.groups.map { group in
                let count = group.items.count == 1 ? "1 video" : "\(group.items.count) videos"
                return MediaSection(
                    id: group.id, title: grouping == .none ? "" : group.title, subtitle: count, items: group.items)
            }
        }
    }

    /// What converting the shown, available items would free with the current preset or Advanced spec.
    /// Kept As Is items count as zero. Cached until the items, the query, the preset or the spec change.
    var couldFreeShown: Int64 {
        let key = SavingsKey(preset: preset, custom: advanced.spec)
        return browser.cached(key) { snapshot in
            couldFreeBytes(for: snapshot.items.filter(\.isAvailable), key: key)
        }
    }

    /// Visible selected items, in grid order; a search or filter that hides an item also deselects it here.
    var selectedItems: [LibraryItem] { browser.selectedItems }

    func couldFreeBytes(for items: [LibraryItem]) -> Int64 {
        couldFreeBytes(for: items, key: SavingsKey(preset: preset, custom: advanced.spec))
    }

    private func couldFreeBytes(for items: [LibraryItem], key: SavingsKey) -> Int64 {
        SavingsCalculator.couldFreeBytes(for: items.map(\.savingsSource), preset: key.preset, custom: key.custom)
    }

    /// Space toggles Quick Look for the selection.
    func toggleQuickLook() {
        quickLookURL = quickLookURL == nil ? selectedItems.first?.url : nil
    }

    var quickLookURLs: [URL] { selectedItems.map(\.url) }
}

private struct SavingsKey: Hashable {
    let preset: Preset
    let custom: DownscaleSpec?
}

extension LibraryItem {
    var savingsSource: SavingsCalculator.Source { (byteSize: byteSize, inventory: inventory) }
    var inspectorSource: InspectorSource {
        InspectorSource(byteSize: byteSize, inventory: inventory, isAvailable: isAvailable)
    }
}
