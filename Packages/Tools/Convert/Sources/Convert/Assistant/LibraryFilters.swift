import Assistant
import Foundation
import LocalLibrary

/// What a plain-words query narrows the grid to, in the app's own filters: nothing the model said reaches the
/// grid except through these.
public struct LibraryFilters: Sendable, Equatable {
    public var mediaType: MediaBadge?
    public var quality = QualityFilter()
    /// Start of the first day, or nil for no lower bound.
    public var since: Date?
    /// End of the last day, or nil for no upper bound.
    public var until: Date?
    /// Hide videos that already have a finished conversion.
    public var notYetShrunk = false
    public var nameText = ""
    public var calendar = Calendar.current

    public init() {}

    public var isEmpty: Bool {
        mediaType == nil && !quality.isActive && since == nil && until == nil && !notYetShrunk && nameText.isEmpty
    }

    public var captureRange: ClosedRange<Date>? {
        guard since != nil || until != nil else { return nil }
        return (since ?? .distantPast)...(until ?? .distantFuture)
    }

    // MARK: Chips

    /// One search token per narrowed dimension, in a fixed order. The name text isn't a token: it goes in the
    /// search field as text.
    public var tokens: [FilterToken] {
        var tokens: [FilterToken] = []
        if let mediaType { tokens.append(FilterToken(kind: .mediaType, title: mediaType.assistantTitle)) }
        if !quality.qualities.isEmpty {
            tokens.append(FilterToken(kind: .quality, title: Phrase.qualities(quality.qualities)))
        }
        if let size = quality.minimumSize { tokens.append(FilterToken(kind: .size, title: size.title)) }
        if !quality.lengths.isEmpty {
            tokens.append(
                FilterToken(kind: .length, title: quality.lengths.sorted().map(\.title).joined(separator: " or ")))
        }
        if !quality.codecs.isEmpty {
            tokens.append(
                FilterToken(kind: .codec, title: quality.codecs.sorted().map(\.title).joined(separator: " or ")))
        }
        if !quality.ranges.isEmpty {
            tokens.append(
                FilterToken(kind: .range, title: quality.ranges.sorted().map(\.title).joined(separator: " or ")))
        }
        if let date = DatePhrase(since: since, until: until, calendar: calendar) {
            tokens.append(FilterToken(kind: .date, title: date.tokenTitle))
        }
        if notYetShrunk { tokens.append(FilterToken(kind: .notYetShrunk, title: "Not yet shrunk")) }
        return tokens
    }

    /// These filters without the dimension a token stands for.
    public func removing(_ kind: FilterToken.Kind) -> LibraryFilters {
        var copy = self
        switch kind {
        case .mediaType: copy.mediaType = nil
        case .quality: copy.quality.qualities = []
        case .size: copy.quality.minimumSize = nil
        case .length: copy.quality.lengths = []
        case .codec: copy.quality.codecs = []
        case .range: copy.quality.ranges = []
        case .date:
            copy.since = nil
            copy.until = nil
        case .notYetShrunk: copy.notYetShrunk = false
        case .name: copy.nameText = ""
        }
        return copy
    }

    // MARK: Echo

    /// A plain sentence saying what is shown: "Showing 4K videos over 500 MB from Jun–Aug 2026".
    public var echo: String {
        if isEmpty { return "Showing all videos" }
        var adjectives: [String] = []
        if let mediaType { adjectives.append(mediaType.assistantTitle) }
        if !quality.ranges.isEmpty { adjectives.append(quality.ranges.sorted().map(\.title).joined(separator: " or ")) }
        if !quality.qualities.isEmpty { adjectives.append(Phrase.qualities(quality.qualities)) }
        if !quality.codecs.isEmpty { adjectives.append(quality.codecs.sorted().map(\.title).joined(separator: " or ")) }
        var parts = ["Showing " + (adjectives + ["videos"]).joined(separator: " ")]
        if let size = quality.minimumSize { parts.append(Phrase.lowercasedFirst(size.title)) }
        if !quality.lengths.isEmpty {
            parts.append(
                "lasting " + quality.lengths.sorted().map { Phrase.lowercasedFirst($0.title) }.joined(separator: " or ")
            )
        }
        if let date = DatePhrase(since: since, until: until, calendar: calendar) { parts.append(date.echoPhrase) }
        if notYetShrunk { parts.append("not yet shrunk") }
        if !nameText.isEmpty { parts.append("named \u{201C}\(nameText)\u{201D}") }
        return parts.joined(separator: " ")
    }
}

/// A search token standing for one narrowed dimension.
public struct FilterToken: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        case mediaType, quality, size, length, codec, range, date, notYetShrunk, name
    }

    public let kind: Kind
    public let title: String
    public var id: Kind { kind }

    /// The SF Symbol shown in the token.
    public var symbolName: String {
        switch kind {
        case .mediaType: "film"
        case .quality: "4k.tv"
        case .size: "internaldrive"
        case .length: "clock"
        case .codec: "film.stack"
        case .range: "sun.max"
        case .date: "calendar"
        case .notYetShrunk: "arrow.down.right.and.arrow.up.left"
        case .name: "textformat"
        }
    }
}

extension MediaBadge {
    var assistantTitle: String {
        switch self {
        case .dolbyVision: "Dolby Vision"
        case .hdr: "HDR"
        case .k4: "4K"
        case .cinematic: "Cinematic"
        case .sloMo: "Slo-mo"
        case .spatial: "Spatial"
        case .edited: "Edited"
        case .sdr: "SDR"
        }
    }
}

enum Phrase {
    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// "4K" when every frame rate of a resolution is chosen, else the buckets by name: "4K60 or 1080p".
    static func qualities(_ buckets: Set<QualityBucket>) -> String {
        var names: [String] = []
        let uhd = buckets.compactMap { bucket -> FrameRateTier? in
            if case .uhd(let tier) = bucket { tier } else { nil }
        }
        let fullHD = buckets.compactMap { bucket -> FrameRateTier? in
            if case .fullHD(let tier) = bucket { tier } else { nil }
        }
        func add(_ name: String, tiers: [FrameRateTier], make: (FrameRateTier) -> QualityBucket) {
            guard !tiers.isEmpty else { return }
            if Set(tiers) == Set(FrameRateTier.allCases) {
                names.append(name)
            } else {
                names.append(contentsOf: tiers.map(make).sorted().map(\.title))
            }
        }
        add("4K", tiers: uhd, make: QualityBucket.uhd)
        add("1080p", tiers: fullHD, make: QualityBucket.fullHD)
        names.append(contentsOf: buckets.filter { !$0.isFrameRateSplit }.sorted().map(\.title))
        return names.joined(separator: " or ")
    }
}

extension QualityBucket {
    fileprivate var isFrameRateSplit: Bool {
        switch self {
        case .uhd, .fullHD: true
        default: false
        }
    }
}

/// A date range in words, from the first and last day it covers.
struct DatePhrase {
    let text: String
    let preposition: String

    var tokenTitle: String {
        preposition == "since" || preposition == "until" ? "\(preposition.capitalized) \(text)" : text
    }
    var echoPhrase: String { "\(preposition) \(text)" }

    init?(since: Date?, until: Date?, calendar: Calendar) {
        guard since != nil || until != nil else { return nil }
        func format(_ date: Date, _ template: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        func isMonthStart(_ date: Date) -> Bool { calendar.dateComponents([.day], from: date).day == 1 }
        func isMonthEnd(_ date: Date) -> Bool {
            guard let next = calendar.date(byAdding: .second, value: 1, to: date) else { return false }
            return calendar.dateComponents([.day], from: next).day == 1
        }
        func day(_ date: Date) -> String { format(date, "dMMMyyyy") }

        switch (since, until) {
        case (let since?, nil):
            self.text = isMonthStart(since) ? format(since, "MMMyyyy") : day(since)
            self.preposition = "since"
        case (nil, let until?):
            self.text = day(until)
            self.preposition = "until"
        case (let since?, let until?):
            let start = calendar.dateComponents([.year, .month, .day], from: since)
            let end = calendar.dateComponents([.year, .month, .day], from: until)
            if isMonthStart(since), isMonthEnd(until) {
                if start.year == end.year, start.month == 1, end.month == 12 {
                    self.text = format(since, "yyyy")
                    self.preposition = "in"
                } else if start.year == end.year, start.month == end.month {
                    self.text = format(since, "MMMyyyy")
                    self.preposition = "in"
                } else if start.year == end.year {
                    self.text = "\(format(since, "MMM"))\u{2013}\(format(until, "MMMyyyy"))"
                    self.preposition = "from"
                } else {
                    self.text = "\(format(since, "MMMyyyy"))\u{2013}\(format(until, "MMMyyyy"))"
                    self.preposition = "from"
                }
            } else if start == end {
                self.text = day(since)
                self.preposition = "on"
            } else if start.year == end.year {
                self.text = "\(format(since, "dMMM"))\u{2013}\(day(until))"
                self.preposition = "from"
            } else {
                self.text = "\(day(since))\u{2013}\(day(until))"
                self.preposition = "from"
            }
        case (nil, nil):
            return nil
        }
    }
}
