import Convert
import AppUI
import LocalLibrary
import SwiftUI

/// The toolbar's Filter menu: quality, size, length, codec and dynamic range, grouped into submenus so every category
/// stays visible at once. Each submenu lists only the options present in the current collection, with how many videos
/// each would show and their total size; the counts come from the browser's cached snapshot. The icon fills in while a
/// filter is on.
struct LibraryFilterMenu: View {
    @Bindable var browser: LibraryBrowser

    var body: some View {
        let facets = browser.snapshot.facets
        let isActive = browser.quality.isActive
        Menu {
            FilterSubmenu(
                title: "Quality", systemImage: "4k.tv", options: facets.qualities,
                selection: $browser.quality.qualities, name: \.title)
            SizeSubmenu(options: facets.sizes, selection: $browser.quality.minimumSize)
            FilterSubmenu(
                title: "Length", systemImage: "clock", options: facets.lengths, selection: $browser.quality.lengths,
                name: \.title)
            FilterSubmenu(
                title: "Codec", systemImage: "film.stack", options: facets.codecs, selection: $browser.quality.codecs,
                name: \.title)
            FilterSubmenu(
                title: "Range", systemImage: "sun.max", options: facets.ranges, selection: $browser.quality.ranges,
                name: \.title)
            if isActive {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle") { browser.quality = QualityFilter() }
            }
        } label: {
            Label(
                "Filter",
                systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .help(isActive ? "Filters are on" : "Show only videos of a quality, size, length, codec or range")
        .accessibilityLabel("Filter")
        .accessibilityValue(isActive ? "On" : "Off")
    }
}

/// A submenu of checkmarked choices; any number can be on, and an item matching any of them is shown.
private struct FilterSubmenu<Value: Hashable & Sendable & Comparable>: View {
    let title: String
    let systemImage: String
    let options: [QualityFacets.Option<Value>]
    @Binding var selection: Set<Value>
    let name: (Value) -> String

    /// Present options plus chosen ones the collection no longer has, so a choice can always be turned off.
    private var rows: [QualityFacets.Option<Value>] {
        let present = Set(options.map(\.value))
        let missing = selection.subtracting(present).map { QualityFacets.Option(value: $0, count: 0, bytes: 0) }
        return (options + missing).sorted { $0.value < $1.value }
    }

    private var activeSummary: String? {
        guard !selection.isEmpty else { return nil }
        return selection.sorted().map(name).joined(separator: ", ")
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            Menu {
                ForEach(rows, id: \.value) { row in
                    Toggle(isOn: isOn(row.value)) {
                        Text(verbatim: optionTitle(name(row.value), row))
                    }
                    .accessibilityLabel(optionTitle(name(row.value), row))
                }
                if !selection.isEmpty {
                    Divider()
                    Button("Clear \(title)") { selection = [] }
                }
            } label: {
                Label {
                    Text(title)
                    if let activeSummary {
                        Text(activeSummary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
            }
        }
    }

    private func isOn(_ value: Value) -> Binding<Bool> {
        Binding {
            selection.contains(value)
        } set: { isOn in
            if isOn { selection.insert(value) } else { selection.remove(value) }
        }
    }
}

/// One "bigger than" threshold, or any size.
private struct SizeSubmenu: View {
    let options: [QualityFacets.Option<SizeThreshold>]
    @Binding var selection: SizeThreshold?

    private var rows: [QualityFacets.Option<SizeThreshold>] {
        guard let selection, !options.contains(where: { $0.value == selection }) else { return options }
        return (options + [QualityFacets.Option(value: selection, count: 0, bytes: 0)]).sorted { $0.value < $1.value }
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            Menu {
                Picker("Size", selection: $selection) {
                    Text("Any Size").tag(SizeThreshold?.none)
                    ForEach(rows, id: \.value) { row in
                        Text(verbatim: optionTitle(row.value.title, row))
                            .tag(Optional(row.value))
                            .accessibilityLabel(optionTitle(row.value.title, row))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label {
                    Text("Size")
                    if let selection {
                        Text(selection.title)
                    }
                } icon: {
                    Image(systemName: "internaldrive")
                }
            }
        }
    }
}

/// "4K60 — 218 videos · 29.8 GB", or "4K60 — none" for a choice the collection no longer has.
private func optionTitle<Value>(_ name: String, _ option: QualityFacets.Option<Value>) -> String {
    guard option.count > 0 else { return "\(name) — none" }
    return "\(name) — \(VideoCount.summary(count: option.count, bytes: option.bytes))"
}
