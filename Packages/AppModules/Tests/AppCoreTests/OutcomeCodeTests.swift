import Foundation
import Testing

@testable import AppCore

@Suite struct OutcomeCodeTests {
    private func outcome(
        warnings: [String] = [], warningCodes: [OutcomeCode] = [], notes: [String] = [], noteCodes: [OutcomeCode] = []
    ) -> JobOutcome {
        JobOutcome(
            output: URL(filePath: "/x/a (smaller).mov"), bytesBefore: 10, bytesAfter: 5, report: MetadataReport(),
            replacedOriginal: false, warnings: warnings, warningCodes: warningCodes, notes: notes,
            noteCodes: noteCodes)
    }

    private func roundTrip(_ state: JobState) throws -> JobState {
        try JSONDecoder().decode(JobState.self, from: JSONEncoder().encode(state))
    }

    // MARK: Saving and reading

    @Test func everyStateSurvivesASaveWithItsCodes() throws {
        let states: [JobState] = [
            .queued,
            .running(progress: 0.25),
            .keptAsIs(reason: "Already small", code: .alreadySmall),
            .failed(reason: "No space", code: .notEnoughSpace),
            .completed(
                outcome(
                    warnings: ["Location is lost"], warningCodes: [.unexpectedLoss], notes: ["Saved to Photos"],
                    noteCodes: [.savedToPhotos])),
        ]
        for state in states { #expect(try roundTrip(state) == state) }
    }

    /// Everything saved before codes existed was written by the compiler's own enum coding: a key per case, the
    /// payload's labels inside. This is that text, written out.
    @Test func resultsSavedBeforeCodesStillOpenAndReadAsOther() throws {
        let kept = try JSONDecoder().decode(
            JobState.self, from: Data(#"{"keptAsIs":{"reason":"Already small"}}"#.utf8))
        #expect(kept == .keptAsIs(reason: "Already small", code: .other))
        let failed = try JSONDecoder().decode(JobState.self, from: Data(#"{"failed":{"reason":"boom"}}"#.utf8))
        #expect(failed == .failed(reason: "boom", code: .other))
        let running = try JSONDecoder().decode(JobState.self, from: Data(#"{"running":{"progress":0.5}}"#.utf8))
        #expect(running == .running(progress: 0.5))
        let queued = try JSONDecoder().decode(JobState.self, from: Data(#"{"queued":{}}"#.utf8))
        #expect(queued == .queued)
    }

    @Test func aCompletedResultSavedBeforeCodesKeepsItsTextsAndReadsTheirCodesAsOther() throws {
        let saved = outcome(warnings: ["Location is lost"], warningCodes: [.unexpectedLoss], notes: ["A note"])
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json["warningCodes"] = nil
        json["noteCodes"] = nil
        let old = try JSONSerialization.data(withJSONObject: ["completed": ["_0": json]])
        guard case .completed(let read) = try JSONDecoder().decode(JobState.self, from: old) else {
            Issue.record("not completed")
            return
        }
        #expect(read.warnings == ["Location is lost"])
        #expect(read.warningCodes == [.other])
        #expect(read.notes == ["A note"])
        #expect(read.noteCodes == [.other])
    }

    @Test func aCodeThisVersionDoesNotKnowReadsAsOther() throws {
        let kept = try JSONDecoder().decode(
            JobState.self, from: Data(#"{"keptAsIs":{"reason":"x","code":"somethingNewer"}}"#.utf8))
        #expect(kept == .keptAsIs(reason: "x", code: .other))
        let codes = try JSONDecoder().decode([OutcomeCode].self, from: Data(#"["savesLittle","nope"]"#.utf8))
        #expect(codes == [.savesLittle, .other])
    }

    @Test func aStateWithNoKnownCaseIsAnError() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(JobState.self, from: Data(#"{"somethingElse":{}}"#.utf8))
        }
    }

    // MARK: Codes pair with texts

    @Test func codesAlwaysPairWithTheirTexts() {
        let short = outcome(warnings: ["a", "b"], warningCodes: [.unexpectedLoss], notes: ["n"])
        #expect(short.warningCodes == [.unexpectedLoss, .other])
        #expect(short.noteCodes == [.other])
        let long = outcome(warnings: ["a"], warningCodes: [.unexpectedLoss, .unexpectedChange])
        #expect(long.warningCodes == [.unexpectedLoss])
    }

    @Test func addingAndRemovingKeepTextsAndCodesTogether() {
        var result = outcome(
            warnings: ["a", "b"], warningCodes: [.unexpectedLoss, .unexpectedChange], notes: ["n", "m"],
            noteCodes: [.savedToPhotos, .originalInRecentlyDeleted])
        result.addWarning("a", code: .other)
        #expect(result.warnings == ["a", "b"])
        result.addWarning("c", code: .originalKeptNotVerified)
        #expect(result.warningCodes == [.unexpectedLoss, .unexpectedChange, .originalKeptNotVerified])
        result.removeWarnings { text, _ in text == "a" }
        #expect(result.warnings == ["b", "c"])
        #expect(result.warningCodes == [.unexpectedChange, .originalKeptNotVerified])
        result.removeNotes { _, code in code == .savedToPhotos }
        #expect(result.notes == ["m"])
        #expect(result.noteCodes == [.originalInRecentlyDeleted])
        result.addNote("g", code: .originalGone)
        #expect(result.notes == ["m", "g"])
        #expect(result.noteCodes == [.originalInRecentlyDeleted, .originalGone])
    }

    // MARK: Errors told by kind

    private struct Plain: Error {}

    private struct Coded: OutcomeCoded, LocalizedError {
        var outcomeCode: OutcomeCode { .photosSaveFailed }
        var errorDescription: String? { "Its own sentence" }
    }

    private struct CodedWithoutSentence: OutcomeCoded {
        var outcomeCode: OutcomeCode { .photosSaveFailed }
    }

    @Test func anErrorOfTheAppsOwnKeepsItsSentenceAndCode() {
        let failure = JobQueue.failure(for: Coded())
        #expect(failure.reason == "Its own sentence")
        #expect(failure.code == .photosSaveFailed)
        let bare = JobQueue.failure(for: CodedWithoutSentence())
        #expect(bare.reason == JobQueue.genericFailureReason)
        #expect(bare.code == .photosSaveFailed)
    }

    private static let systemCases: [(String, Int, OutcomeCode)] = [
        (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue, .originalUnavailable),
        (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue, .originalUnavailable),
        (NSPOSIXErrorDomain, Int(ENOENT), .originalUnavailable),
        (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue, .notEnoughSpace),
        (NSPOSIXErrorDomain, Int(ENOSPC), .notEnoughSpace),
        (NSCocoaErrorDomain, CocoaError.fileWriteNoPermission.rawValue, .outputFolderUnavailable),
        (NSCocoaErrorDomain, CocoaError.fileWriteVolumeReadOnly.rawValue, .outputFolderUnavailable),
        (NSPOSIXErrorDomain, Int(EROFS), .outputFolderUnavailable),
        (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue, .conversionFailed),
        (NSPOSIXErrorDomain, Int(EACCES), .conversionFailed),
    ]

    /// The system words its errors in the user's language, so the kind is read from the domain and the code, and
    /// the system's own sentence is kept (it says which file).
    @Test func systemErrorsAreToldByDomainAndCodeAndKeepTheirOwnSentence() {
        for (domain, code, expected) in Self.systemCases {
            let own = "Die Datei „Urlaub.mov“ konnte nicht geöffnet werden."
            let error = NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: own])
            let failure = JobQueue.failure(for: error)
            #expect(failure.code == expected, "\(domain) \(code)")
            #expect(failure.reason == own, "\(domain) \(code)")
        }
    }

    /// The generic form names a domain and a number in whatever language the system speaks; none of that is shown.
    @Test func theGenericSystemFormIsReplacedByAPlainSentenceInAnyLanguage() {
        for (domain, code, expected) in Self.systemCases {
            let generic = "Der Vorgang konnte nicht abgeschlossen werden. (Cocoa-Fehler \(code).)"
            let error = NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: generic])
            let failure = JobQueue.failure(for: error)
            #expect(failure.code == expected, "\(domain) \(code)")
            #expect(failure.reason != generic, "\(domain) \(code)")
            #expect(!failure.reason.contains("\(code)"), "\(domain) \(code)")
        }
        let unknown = NSError(
            domain: NSCocoaErrorDomain, code: 99_999,
            userInfo: [NSLocalizedDescriptionKey: "Opération impossible. (Cocoa error 99999.)"])
        #expect(JobQueue.failure(for: unknown).reason == JobQueue.genericFailureReason)
    }

    @Test func anyOtherErrorIsTheGenericSentenceWhateverLanguageTheSystemSpeaks() {
        // What a Swift error without a description bridges to, in German: no English prefix to match.
        let german = NSError(
            domain: "AppModules.Plain", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Der Vorgang konnte nicht abgeschlossen werden. (Plain-Fehler 1.)"
            ])
        for error in [german as any Error, Plain(), NSError(domain: "AVFoundationErrorDomain", code: -11800)] {
            let failure = JobQueue.failure(for: error)
            #expect(failure.reason == JobQueue.genericFailureReason)
            #expect(failure.code == .conversionFailed)
        }
    }

    @Test func aFailedRunIsRecordedWithItsCode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OutcomeCode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = JobQueue(store: JobStore(directory: directory), runners: ["t": CodedRunner()])
        let job = Job(toolID: "t", source: URL(filePath: "/x/a.mov"), sourceBookmark: Data(), settings: Data())
        await queue.enqueue([job])
        for await jobs in await queue.updates() {
            if case .failed = jobs.first?.state { break }
        }
        #expect(await queue.jobs.first?.state == .failed(reason: "Its own sentence", code: .photosSaveFailed))
    }

    private struct CodedRunner: JobRunner {
        func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
            throw Coded()
        }
    }
}
