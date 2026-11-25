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

    /// What converting the shown, available items would free, each with its own preset (the header's unless the
    /// inspector chose another), or all with the Advanced spec. Kept As Is items count as zero. Cached until the
    /// items, the query, the presets or the spec change.
    var couldFreeShown: Int64 {
        let key = SavingsKey(preset: preset, custom: advanced.spec, overrides: presetOverrides)
        return browser.cached(key) { snapshot in
            key.overrides.couldFreeBytes(
                for: snapshot.items.filter(\.isAvailable).map { (id: $0.id, source: $0.savingsSource) },
                default: key.preset, custom: key.custom)
        }
    }

    /// Visible selected items, in grid order; a search or filter that hides an item also deselects it here.
    var selectedItems: [LibraryItem] { browser.selectedItems }

    /// The preset `item` converts with: its own from the inspector, else the header's.
    func effectivePreset(for item: LibraryItem) -> Preset {
        presetOverrides.preset(for: item.id, default: preset)
    }

    /// The inspector's preset: the one every selected video converts with, nil when they differ ("Mixed").
    /// Choosing one gives it to every selected video, leaving the header's preset alone.
    var selectionPreset: Preset? {
        get { presetOverrides.selectionPreset(for: selectedItems.map(\.id), default: preset) }
        set {
            guard let newValue else { return }
            presetOverrides.set(newValue, for: selectedItems.map(\.id), default: preset)
        }
    }

    func inspectorSource(for item: LibraryItem) -> InspectorSource {
        InspectorSource(
            byteSize: item.byteSize, inventory: item.inventory, isAvailable: item.isAvailable,
            preset: effectivePreset(for: item))
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
    let overrides: PresetOverrides<UUID>
}

extension LibraryItem {
    var savingsSource: SavingsCalculator.Source { (byteSize: byteSize, inventory: inventory) }
}

extension AppModel {
    /// Whether Remove from library has anything to remove: visible selected items on a library screen.
    var canRemoveSelectionFromLibrary: Bool {
        selection?.showsLibrary == true && !selectedItems.isEmpty
    }

    /// Removes the visible selected items from the library. The files themselves are never touched.
    func removeSelectionFromLibrary() {
        guard canRemoveSelectionFromLibrary else { return }
        removeFromLibrary(Set(selectedItems.map(\.id)))
    }

    /// From a tile's context menu: the visible selection when the tile is part of it, else just that tile.
    func removeFromLibrary(clicked item: LibraryItem) {
        let selected = Set(selectedItems.map(\.id))
        removeFromLibrary(selected.contains(item.id) ? selected : [item.id])
    }

    private func removeFromLibrary(_ ids: Set<UUID>) {
        library.remove(ids)
        presetOverrides.remove(ids)
        browser.selection.subtract(ids)
        if let url = quickLookURL, !library.items.contains(where: { $0.url == url }) { quickLookURL = nil }
    }
}
