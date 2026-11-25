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

    private var tokens: Binding<[FilterToken]> {
        Binding(
            get: { search.isVisible ? search.tokens : [] },
            set: { search.tokensChanged(to: $0, browser: browser, sidebarBadge: sidebarBadge) })
    }

    func body(content: Content) -> some View {
        content
            .searchable(text: $browser.search, tokens: tokens, placement: .toolbar, prompt: "Search by name") { token in
                Label(token.title, systemImage: token.symbolName)
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
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if search.isVisible, !search.note.isEmpty {
                    Text(search.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .accessibilityLabel(search.note)
                }
            }
            .onChange(of: search.isVisible, initial: true) {
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

extension AppModel {
    /// The Local Files items that already have a finished conversion, or are one: "not yet shrunk" hides them.
    func shrunkIDs(in browser: LibraryBrowser) -> Set<UUID> {
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
