import AppCore
import Convert
import Foundation
import MediaEngine
import PhotosLibrary
import Testing

@testable import AppCore
@testable import Assistant
@testable import Convert

/// Every reason the app writes carries its code from the place that writes it. These tests build their inputs from
/// the real sources (planner decisions, error types, warning and note builders), so a new reason without a code
/// fails here instead of reaching the Assistant as "another detail".
@Suite struct OutcomeReasonSourceTests {
    private static let item = MetadataItem(
        key: "qt.uiso/loci", category: .location, displayName: "Location", value: "x")

    // MARK: Kept as is

    @Test func theCodeComesFromTheSourceThatDecidesNotFromItsWording() {
        func code(_ decision: PlanDecision) -> OutcomeCode? {
            if case .keptAsIs(_, let code) = decision { return code }
            return nil
        }
        let stereo = MetadataInventory(items: [
            MetadataItem(key: "hdr.stereo", category: .hdr, displayName: "Stereo views", value: "2")
        ])
        #expect(
            code(ConvertPlanner.decide(inventory: stereo, byteSize: 1_000, spec: DownscaleSpec())) == .spatialVideo)
        #expect(
            code(ConvertPlanner.decide(inventory: MetadataInventory(), byteSize: 1_000, spec: DownscaleSpec()))
                == .lengthUnreadable)
    }

    // MARK: Failures

    /// Failures: the code the queue records for each error type the runners throw.
    private static let failures: [(any Error, OutcomeCode)] = [
        (ConvertRunnerError.sourceUnavailable, .originalUnavailable),
        (ConvertRunnerError.outputFolderUnavailable, .outputFolderUnavailable),
        (ConvertRunnerError.nameTaken, .outputNameTaken),
        (DownscaleError.outputExists, .outputNameTaken),
        (DownscaleError.sourceAlreadySmall, .alreadySmall),
        (DownscaleError.unsupportedSource("x"), .unsupportedVideo),
        (DownscaleError.encoderFailed("x"), .conversionFailed),
        (PhotosRunnerError.notAPhotosJob, .unsupportedVideo),
        (
            NotEnoughSpaceError(volumeName: "Macintosh HD", neededBytes: 80_000_000, availableBytes: 1_000),
            .notEnoughSpace
        ),
        (DownscaleError.stalled, .conversionFailed),
        (PhotoFetchError.notInLibrary, .originalUnavailable),
        (PhotoFetchError.downloadFailed(underlying: "x"), .iCloudDownloadFailed),
        (PhotoFetchError.cancelled, .cancelled),
        (PhotoFetchError.notAuthorized, .photosAccessDenied),
        (PhotoFetchError.failed("x"), .originalUnavailable),
        (PhotoStoreError.notAuthorized, .photosAccessDenied),
        (PhotoStoreError.notInLibrary("x"), .originalUnavailable),
        (PhotoStoreError.downloadFailed("x"), .iCloudDownloadFailed),
        (PhotoStoreError.unavailable("x"), .originalUnavailable),
        (PhotoSaveError.saveFailed("x"), .photosSaveFailed),
        (PhotoSaveError.verifyFailed(reasons: [], cleanup: .removed), .photosSaveFailed),
        (PhotoSaveError.cancelled, .cancelled),
    ]

    @Test func everyErrorTheRunnersThrowCarriesItsCode() {
        for (error, code) in Self.failures {
            let failure = JobQueue.failure(for: error)
            #expect(failure.code == code, "\(error)")
            #expect(failure.reason == (error as? any LocalizedError)?.errorDescription, "\(error)")
        }
    }

    // MARK: Warnings and notes

    @Test func warningsCarryTheCodeOfWhatWasFound() {
        let report = MetadataReport(lost: [Self.item])
        let lost = ConvertRunner.warningLines(report, predicted: MetadataReport(), spec: DownscaleSpec())
        #expect(!lost.isEmpty)
        #expect(lost.allSatisfy { $0.code == .unexpectedLoss })
        #expect(
            ConvertRunner.warnings(report, predicted: MetadataReport(), spec: DownscaleSpec()) == lost.map(\.text))
        let change = MetadataChange(key: "video.bitDepth", displayName: "Bit depth", from: "8", to: "10")
        let changed = ConvertRunner.warningLines(
            MetadataReport(changed: [change]), predicted: MetadataReport(),
            spec: DownscaleSpec(targetShortSide: 1080, averageBitRate: 8_000_000))
        #expect(changed.map(\.code) == [.unexpectedChange])
    }

    // MARK: The prompt reads codes

    @Test func thePromptReadsTheCodesAndNeverTheTexts() {
        let source = URL(filePath: "/Users/jane/Cancelled trip.mov")
        let output = URL(filePath: "/Users/jane/Cancelled trip (smaller).mov")
        let note = ConvertRunner.renamedNote(
            output: output, target: URL(filePath: "/Users/jane/Cancelled trip.mp4"), why: "already exists")
        let outcome = JobOutcome(
            output: output, bytesBefore: 10, bytesAfter: 5, report: MetadataReport(), replacedOriginal: false,
            notes: [note], noteCodes: [.nameChanged], source: source)
        let job = Job(
            toolID: ConvertTool.toolID, source: source, sourceBookmark: Data(), settings: Data(),
            state: .completed(outcome))
        let prompt = OutcomeExplainer.prompt(job: job, outcome: outcome, report: outcome.report)
        #expect(prompt.contains("Note: \(OutcomeCode.nameChanged.sentence)"))
        #expect(!prompt.contains(OutcomeCode.cancelled.sentence))
        #expect(!prompt.contains("Cancelled"))
        #expect(!prompt.contains("Jane"))
    }

    @Test func aReasonTextThatLooksLikeAnotherReasonDoesNotChangeTheCode() {
        // The words say "cancelled"; the code says the video was already small. The code decides.
        let state = JobState.keptAsIs(reason: "Cancelled trip: already small", code: .alreadySmall)
        let job = Job(
            toolID: ConvertTool.toolID, source: URL(filePath: "/x/a.mov"), sourceBookmark: Data(), settings: Data(),
            state: state)
        let prompt = OutcomeExplainer.prompt(job: job, outcome: nil, report: nil)
        #expect(prompt.contains("Reason: \(OutcomeCode.alreadySmall.sentence)"))
        #expect(!prompt.contains("Cancelled"))
    }

    @Test func aResultSavedWithoutCodesReadsAsOther() throws {
        let json = #"{"failed":{"reason":"Couldn't download from iCloud. Check that you're online."}}"#
        let state = try JSONDecoder().decode(JobState.self, from: Data(json.utf8))
        let job = Job(
            toolID: ConvertTool.toolID, source: URL(filePath: "/x/a.mov"), sourceBookmark: Data(), settings: Data(),
            state: state)
        let prompt = OutcomeExplainer.prompt(job: job, outcome: nil, report: nil)
        #expect(prompt.contains("Reason: \(OutcomeCode.other.sentence)"))
        #expect(!prompt.contains("iCloud"))
    }

    @Test func everyCodeHasItsOwnSentence() {
        let sentences = OutcomeCode.allCases.map(\.sentence)
        #expect(Set(sentences).count == sentences.count)
    }
}
