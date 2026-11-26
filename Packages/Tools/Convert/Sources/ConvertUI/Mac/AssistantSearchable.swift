import Convert
import Assistant
import AppCore
import Foundation
import LocalLibrary
import SwiftUI

extension View {
    /// The grid's name search, with "Ask in plain words" when Apple Intelligence is available: a sparkles button
    /// and Return on a sentence turn the words into filters, shown as system search tokens. With the model
    /// unavailable this is the plain name search and nothing else.
    func assistantSearchable(
        search: AssistantSearch, browser: LibraryBrowser, sidebarBadge: MediaBadge?,
        shrunkIDs: (@MainActor () -> Set<UUID>)?
    ) -> some View {
        modifier(
            AssistantSearchable(search: search, browser: browser, sidebarBadge: sidebarBadge, shrunkIDs: shrunkIDs))
    }
}

private struct AssistantSearchable: ViewModifier {
    let search: AssistantSearch
    @Bindable var browser: LibraryBrowser
    let sidebarBadge: MediaBadge?
    let shrunkIDs: (@MainActor () -> Set<UUID>)?
    @FocusState private var isSearchFocused: Bool

    private var tokens: Binding<[FilterToken]> {
        Binding(
            get: { search.showsFilters ? search.tokens : [] },
            set: { search.tokensChanged(to: $0, browser: browser, sidebarBadge: sidebarBadge) })
    }

    func body(content: Content) -> some View {
        content
            .searchable(text: $browser.search, tokens: tokens, placement: .toolbar, prompt: "Search") { token in
                Label(token.title, systemImage: token.symbolName)
                    .accessibilityLabel("Filter: \(token.title)")
                    .accessibilityHint("Press Delete to remove this filter")
            }
            .searchFocused($isSearchFocused)
            // A person who turned Apple Intelligence on in System Settings sees the button without leaving the app.
            .onChange(of: isSearchFocused) { _, isFocused in
                if isFocused { search.searchFieldGainedFocus() }
            }
            .onSubmit(of: .search) {
                if search.isVisible, AssistantSearch.looksLikeSentence(browser.search) { ask() }
            }
            .toolbar {
                if search.isVisible {
                    ToolbarItem {
                        Button("Ask in Plain Words", systemImage: "sparkles") { ask() }
                            .disabled(browser.search.trimmingCharacters(in: .whitespaces).isEmpty || search.isWorking)
                            .help("Turn what you typed into filters, on this Mac")
                            .accessibilityLabel("Ask in Plain Words")
                            .accessibilityHint(
                                "Turns what you typed in the search field into filters. Runs on this Mac.")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if search.showsFilters, !search.note.isEmpty {
                    Text(search.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .accessibilityLabel(search.note)
                }
            }
            .onChange(of: search.showsFilters, initial: true) {
                search.availabilityChanged(browser: browser, sidebarBadge: sidebarBadge)
            }
    }

    private func ask() {
        let text = browser.search
        let sidebarBadge = sidebarBadge
        let shrunk = shrunkIDs?()
        Task { await search.submit(text, browser: browser, sidebarBadge: sidebarBadge, shrunkIDs: shrunk) }
    }
}
