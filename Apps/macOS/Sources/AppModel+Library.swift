import SharedUI
import Convert
import Foundation
import LocalLibrary
import MediaEngine

extension AppModel {
    /// The media-type filter when the sidebar points at one.
    var badgeFilter: MediaBadge? {
        if case .mediaType(let badge) = selection { return badge }
        return nil
    }

    /// Whether the Videos (Photos) page is showing. The queue, Quick Look and Remove only ever act on Local Files,
    /// so `selectedItems` is empty there.
    var isPhotosPage: Bool { selection == .photosVideos }

    /// The inspector belongs to the library grids; the Activity lists don't show it.
    var inspectorAvailable: Bool { selection?.showsLibrary == true || isPhotosPage }

    /// The grid's sections, built once per change of the library or the query (never per selection change).
    var sections: [MediaSection<LibraryItem>] { Self.sections(of: browser) }

    /// The Videos page's sections.
    var photoSections: [MediaSection<LibraryItem>] { Self.sections(of: photosBrowser) }

    private static func sections(of browser: LibraryBrowser) -> [MediaSection<LibraryItem>] {
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

    /// Visible selected Local Files items, in grid order; a search or filter that hides an item also deselects it
    /// here. Empty on the Videos page, so nothing there reaches the file-based queue, Quick Look or Remove.
    var selectedItems: [LibraryItem] { isPhotosPage ? [] : browser.selectedItems }

    /// Visible selected Photos videos, in grid order.
    var selectedPhotoItems: [LibraryItem] { photosBrowser.selectedItems }

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
        quickLookURL = quickLookURL == nil ? selectedItems.first?.fileURL : nil
    }

    var quickLookURLs: [URL] { selectedItems.compactMap(\.fileURL) }
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
        removeFromLibrary(contextTargetIDs(clicked: item))
    }

    /// The ids a tile's context menu acts on (`ContextMenuTargets`).
    private func contextTargetIDs(clicked item: LibraryItem) -> Set<UUID> {
        ContextMenuTargets.ids(clicked: item.id, selection: Set(selectedItems.map(\.id)))
    }

    /// The items a tile's context menu acts on, in grid order.
    func contextTargets(clicked item: LibraryItem) -> [LibraryItem] {
        let ids = contextTargetIDs(clicked: item)
        return ids == [item.id] ? [item] : selectedItems.filter { ids.contains($0.id) }
    }

    /// Selects what a context menu acts on, as Finder does when the clicked item isn't part of the selection.
    private func selectContextTargets(clicked item: LibraryItem) {
        // A clicked tile that is already selected leaves the selection alone, so a hidden selection survives.
        if !selectedItems.contains(where: { $0.id == item.id }) { browser.selection = [item.id] }
    }

    /// Context menu: Add to queue, for the selection or the clicked tile.
    func addToQueue(clicked item: LibraryItem) {
        selectContextTargets(clicked: item)
        requestAddSelectionToQueue()
    }

    func canAddToQueue(clicked item: LibraryItem) -> Bool {
        saveLocation.destination != nil && contextTargets(clicked: item).contains(where: \.isAvailable)
    }

    /// Context menu: Quick Look, for the selection or the clicked tile (Space does the same for the selection).
    func quickLook(clicked item: LibraryItem) {
        selectContextTargets(clicked: item)
        quickLookURL = item.fileURL
    }

    /// `undoable`: Edit → Undo can put the items back (not for the removal an Undo's Redo performs itself).
    func removeFromLibrary(_ ids: Set<UUID>, undoable: Bool = true) {
        if undoable { registerUndo(of: LibraryRemoval(items: library.items.filter { ids.contains($0.id) })) }
        library.remove(ids)
        presetOverrides.remove(ids)
        browser.selection.subtract(ids)
        if let url = quickLookURL, !library.items.contains(where: { $0.fileURL == url }) { quickLookURL = nil }
    }
}
