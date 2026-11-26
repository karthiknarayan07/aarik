import Foundation
import Testing

@testable import Assistant

@Suite struct TemporalCueTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private static let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25))!
    private static let todayOnly = LibraryQuery(
        resolutions: ["4K"], startDate: "2026-11-25", endDate: "2026-11-25")

    private func translate(_ query: LibraryQuery, _ text: String) async -> TranslatedQuery {
        let client = FakeLanguageModelClient(returning: query)
        return await QueryTranslator(client: client).translate(text, today: Self.today, calendar: Self.calendar)
    }

    @Test func englishRequestWithoutATimeLosesAnInventedRangeAndSaysSo() async {
        let result = await translate(Self.todayOnly, "show me my 4K videos")
        #expect(result.filters.captureRange == nil)
        #expect(!result.filters.quality.qualities.isEmpty)
        #expect(result.dropped == ["Ignored a date range that wasn\u{2019}t in your request."])
    }

    @Test func englishRequestWithATimeKeepsItsRange() async {
        for text in ["4K videos from today", "4K videos from this week", "4K videos tonight", "4K videos from 2026"] {
            let result = await translate(Self.todayOnly, text)
            #expect(result.filters.captureRange != nil, "\(text)")
            #expect(result.dropped.isEmpty, "\(text)")
        }
    }

    @Test func otherLanguagesKeepTheModelsRangeAsARemovableToken() async {
        let result = await translate(
            Self.todayOnly, "Quiero ver todos los videos de este mes que sean muy grandes")
        #expect(result.filters.captureRange != nil)
        #expect(result.filters.tokens.contains { $0.kind == .date })
        #expect(result.dropped.isEmpty)
        let german = await translate(Self.todayOnly, "Zeige mir bitte alle Videos von heute Abend")
        #expect(german.filters.captureRange != nil)
    }

    @Test func languageDetectionFallsBackToTheLocaleForShortText() {
        #expect(QueryTranslator.isEnglish("4K", locale: Locale(identifier: "en_US")))
        #expect(!QueryTranslator.isEnglish("4K", locale: Locale(identifier: "de_DE")))
        #expect(
            !QueryTranslator.isEnglish("Quiero ver los videos de ayer por favor", locale: Locale(identifier: "en_US")))
    }
}
