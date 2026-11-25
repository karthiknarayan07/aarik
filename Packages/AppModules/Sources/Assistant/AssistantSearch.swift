import Foundation
import LocalLibrary
import Observation

/// "Ask in plain words" for one library grid: turns a sentence into the app's filters, shows them as search
/// tokens the user can remove, and says in plain words what is shown.
///
/// Everything is hidden while the model is unavailable (`isVisible`), and a failed or useless answer becomes an
/// ordinary name search, so the plain search never stops working. The model only ever sets filters the user can
/// see and remove; it never queues, deletes or replaces anything.
@MainActor
@Observable
public final class AssistantSearch {
    public let availability: AssistantAvailability
    private let translator: QueryTranslator

    /// Whether any assistant control may be shown.
    public var isVisible: Bool { availability.isAvailable }
    public private(set) var isWorking = false
    /// The applied filters as system search tokens.
    public private(set) var tokens: [FilterToken] = []
    /// What is shown, in a sentence, plus notes on anything dropped; empty when nothing was applied.
    public private(set) var note = ""

    @ObservationIgnored private var filters = LibraryFilters()
    @ObservationIgnored private var shrunkIDs: Set<UUID> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasApplied = false

    public init(availability: AssistantAvailability, translator: QueryTranslator) {
        self.availability = availability
        self.translator = translator
    }

    /// Return in the search field goes to the model only for something that reads as a sentence.
    public static func looksLikeSentence(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 3
    }

    /// Translates `text` and applies the result to `browser`. `shrunkIDs` are the items with a finished
    /// conversion, hidden by "not yet shrunk"; `sidebarBadge` is the media type the sidebar page already imposes.
    public func submit(
        _ text: String, browser: LibraryBrowser, sidebarBadge: MediaBadge?, shrunkIDs: Set<UUID>,
        today: Date = .now
    ) async {
        guard isVisible else { return }
        generation += 1
        let mine = generation
        isWorking = true
        let result = await translator.translate(text, today: today)
        guard mine == generation else { return }
        isWorking = false
        guard isVisible else { return }

        if result.failure != nil || (result.filters.isEmpty && result.dropped.isEmpty) {
            // Nothing usable from the model: a plain name search, as if the assistant didn't exist.
            clear(browser: browser, sidebarBadge: sidebarBadge)
            browser.search = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if result.filters.isEmpty {
            note = result.dropped.joined(separator: " ")
            return
        }
        self.shrunkIDs = shrunkIDs
        filters = result.filters
        apply(browser: browser, sidebarBadge: sidebarBadge)
        note = ([result.echo] + result.dropped).joined(separator: " ")
    }

    /// The user removed tokens in the search field: drop those filters.
    public func tokensChanged(to remaining: [FilterToken], browser: LibraryBrowser, sidebarBadge: MediaBadge?) {
        let kept = Set(remaining.map(\.kind))
        for token in tokens where !kept.contains(token.kind) {
            filters = filters.removing(token.kind)
        }
        if filters.isEmpty {
            clear(browser: browser, sidebarBadge: sidebarBadge)
            return
        }
        apply(browser: browser, sidebarBadge: sidebarBadge)
        note = filters.echo
    }

    /// Removes every filter this search applied.
    public func reset(browser: LibraryBrowser, sidebarBadge: MediaBadge?) {
        generation += 1
        isWorking = false
        guard hasApplied || !note.isEmpty else { return }
        clear(browser: browser, sidebarBadge: sidebarBadge)
        browser.search = ""
    }

    /// Call when availability may have changed or a page appears: if the model went away, so do its filters.
    public func availabilityChanged(browser: LibraryBrowser, sidebarBadge: MediaBadge?) {
        if !isVisible { reset(browser: browser, sidebarBadge: sidebarBadge) }
    }

    private func apply(browser: LibraryBrowser, sidebarBadge: MediaBadge?) {
        browser.filter = filters.mediaType ?? sidebarBadge
        browser.quality = filters.quality
        browser.captureRange = filters.captureRange
        browser.excluded = filters.notYetShrunk ? shrunkIDs : []
        browser.search = filters.nameText
        tokens = filters.tokens
        hasApplied = true
    }

    private func clear(browser: LibraryBrowser, sidebarBadge: MediaBadge?) {
        let hadApplied = hasApplied
        hasApplied = false
        filters = LibraryFilters()
        tokens = []
        note = ""
        guard hadApplied else { return }
        browser.filter = sidebarBadge
        browser.quality = QualityFilter()
        browser.captureRange = nil
        browser.excluded = []
        browser.search = ""
    }
}
