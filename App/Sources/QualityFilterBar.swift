import AppUI
import LocalLibrary
import SwiftUI

/// Quality, size, length, codec and dynamic-range menus above the grid. Each lists only the options present in the
/// current collection, with how many videos each would show and their total size; the counts come from the browser's
/// cached snapshot.
struct QualityFilterBar: View {
    @Bindable var browser: LibraryBrowser

    var body: some View {
        let facets = browser.snapshot.facets
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                FilterMenu(
                    title: "Quality", systemImage: "4k.tv", options: facets.qualities,
                    selection: $browser.quality.qualities, name: \.title)
                SizeMenu(options: facets.sizes, selection: $browser.quality.minimumSize)
                FilterMenu(
                    title: "Length", systemImage: "clock", options: facets.lengths,
                    selection: $browser.quality.lengths, name: \.title)
                FilterMenu(
                    title: "Codec", systemImage: "film", options: facets.codecs,
                    selection: $browser.quality.codecs, name: \.title)
                FilterMenu(
                    title: "Range", systemImage: "sun.max", options: facets.ranges,
                    selection: $browser.quality.ranges, name: \.title)
                if browser.quality.isActive {
                    Button("Clear", systemImage: "xmark.circle") { browser.quality = QualityFilter() }
                        .buttonStyle(.borderless)
                        .help("Show videos of every quality, size, length, codec and range")
                        .accessibilityLabel("Clear quality filters")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quality filters")
    }
}

/// A pull-down of checkmarked choices; any number can be on, and an item matching any of them is shown.
private struct FilterMenu<Value: Hashable & Sendable & Comparable>: View {
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
                    Button("Show All") { selection = [] }
                }
            } label: {
                Label(label, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .menuIndicator(.visible)
            .fixedSize()
            .help("Show only videos with the chosen \(title.lowercased())")
            .accessibilityLabel("\(title) filter")
            .accessibilityValue(accessibilityValue)
        }
    }

    private var chosen: [Value] { selection.sorted() }

    private var label: String {
        switch chosen.count {
        case 0: title
        case 1: "\(title): \(name(chosen[0]))"
        default: "\(title): \(chosen.count)"
        }
    }

    private var accessibilityValue: String {
        chosen.isEmpty ? "Any" : chosen.map(name).formatted(.list(type: .or))
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
private struct SizeMenu: View {
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
                Label(selection?.title ?? "Size", systemImage: "internaldrive")
                    .labelStyle(.titleAndIcon)
            }
            .menuIndicator(.visible)
            .fixedSize()
            .help("Show only videos bigger than a size")
            .accessibilityLabel("Size filter")
            .accessibilityValue(selection?.title ?? "Any size")
        }
    }
}

/// "4K60 — 218 videos · 29.8 GB", or "4K60 — none" for a choice the collection no longer has.
private func optionTitle<Value>(_ name: String, _ option: QualityFacets.Option<Value>) -> String {
    guard option.count > 0 else { return "\(name) — none" }
    return "\(name) — \(VideoCount.summary(count: option.count, bytes: option.bytes))"
}
