import AppCore
import DownscaleVideo
import Foundation
import MediaEngine
import PhotosLibrary
import Testing

@testable import AppCore
@testable import Assistant
@testable import DownscaleVideo

/// The reason codes are matched to the wording the app writes. These tests build their inputs from the real
/// sources (constants, static builders, error descriptions), so rewording one in the runners fails here instead
/// of turning real results into "another detail" without a sound.
@Suite struct OutcomeReasonSourceTests {
    private static let backupReasons = [
        OriginalsBackupError.folderUnavailable, .copyFailed, .sizeMismatch,
    ].map(\.keptBecause)

    private static let item = MetadataItem(
        key: "qt.uiso/loci", category: .location, displayName: "Location", value: "x")

    /// Every reason a job can be kept as is with, from the planner and the runners.
    private static var keptReasons: [(String, OutcomeReason)] {
        [
            (DownscalePlanner.alreadySmallReason, .alreadySmall),
            (DownscalePlanner.savesLittleReason, .savesLittle),
            (DownscalePlanner.spatialReason, .spatialVideo),
            (DownscalePlanner.lengthUnreadableReason, .lengthUnreadable),
            (DownscaleRunner.formatCantKeepDetails, .formatCannotKeepDetails),
            (DownscaleRunner.lossNotShownReason("Location"), .lossNotShownBeforeAdding),
        ]
    }

    /// Failures: the queue's own reason text for each error type the runners throw.
    private static var failureReasons: [(String, OutcomeReason)] {
        let errors: [(any Error, OutcomeReason)] = [
            (DownscaleRunnerError.sourceUnavailable, .originalUnavailable),
            (DownscaleRunnerError.outputFolderUnavailable, .outputFolderUnavailable),
            (DownscaleRunnerError.nameTaken, .outputNameTaken),
            (DownscaleError.outputExists, .outputNameTaken),
            (DownscaleError.sourceAlreadySmall, .alreadySmall),
            (DownscaleError.unsupportedSource("x"), .unsupportedVideo),
            (DownscaleError.encoderFailed("x"), .conversionFailed),
            (PhotosRunnerError.notEnoughSpace(needed: 80_000_000), .notEnoughSpace),
            (PhotoFetchError.notInLibrary, .originalUnavailable),
            (PhotoFetchError.downloadFailed(underlying: "x"), .iCloudDownloadFailed),
            (PhotoFetchError.cancelled, .cancelled),
            (PhotoStoreError.notAuthorized, .photosAccessDenied),
            (PhotoStoreError.notInLibrary("x"), .originalUnavailable),
            (PhotoStoreError.downloadFailed("x"), .iCloudDownloadFailed),
            (PhotoSaveError.saveFailed("x"), .photosSaveFailed),
            (PhotoSaveError.verifyFailed(reasons: [], cleanup: .removed), .photosSaveFailed),
            (PhotoSaveError.verifyFailed(reasons: [], cleanup: .declined), .photosSaveFailed),
            (PhotoSaveError.verifyFailed(reasons: [], cleanup: .failed("x")), .photosSaveFailed),
        ]
        return errors.map { (JobQueue.reason(for: $0.0), $0.1) } + [(JobQueue.noToolReason, .noToolForJob)]
    }

    private static var warningTexts: [(String, OutcomeReason)] {
        var texts: [(String, OutcomeReason)] = [
            (DownscaleRunner.originalChanged, .originalChangedDuringConversion),
            (PhotosDownscaleRunner.originalChanged, .originalChangedDuringConversion),
            (PhotosDownscaleRunner.albumsWarning, .notAddedToAlbums),
            (DownscaleRunner.keptBecause(DownscaleRunner.trashFailedReason), .originalKeptCouldNotTrash),
            (DownscaleRunner.keptBecause(DownscaleRunner.unverifiedCopyReason), .originalKeptNotVerified),
            (PhotosDownscaleRunner.keptBecause(DownscaleRunner.unverifiedCopyReason), .originalKeptNotVerified),
            (PhotosDownscaleRunner.keptBecause(PhotosDownscaleRunner.backupDownloadReason), .originalKeptBackupFailed),
        ]
        texts += backupReasons.map { (DownscaleRunner.keptBecause($0), OutcomeReason.originalKeptBackupFailed) }
        texts += PendingBlock.allCases.map { ($0.message, OutcomeReason.originalKeptOtherReason) }
        let report = MetadataReport(lost: [item])
        for warning in DownscaleRunner.warnings(report, predicted: MetadataReport(), spec: DownscaleSpec()) {
            texts.append((warning, .unexpectedLoss))
        }
        let change = MetadataChange(key: "video.codec", displayName: "Codec", from: "hvc1", to: "avc1")
        texts.append((MetadataNames.changeSentence(change), .unexpectedChange))
        return texts
    }

    private static var noteTexts: [(String, OutcomeReason)] {
        let output = URL(filePath: "/x/Beach (smaller).mov")
        let target = URL(filePath: "/x/Beach.mp4")
        return [
            (
                DownscaleRunner.containerNote(source: URL(filePath: "/x/Beach.mp4"), pathExtension: "mov"),
                .containerChanged
            ),
            (DownscaleRunner.renamedNote(output: output, target: target, why: "already exists"), .nameChanged),
            (DownscaleRunner.renamedNote(output: output, target: target, why: "couldn't be used"), .nameChanged),
            (PhotosDownscaleRunner.savedNote, .savedToPhotos),
            (PhotosDownscaleRunner.recentlyDeletedNote, .originalInRecentlyDeleted),
            (PhotosDownscaleRunner.movedNote, .originalInRecentlyDeleted),
            (PhotosDownscaleRunner.goneNote, .originalGone),
        ]
    }

    private static var everything: [(String, OutcomeReason)] {
        keptReasons + failureReasons + warningTexts + noteTexts
    }

    @Test func everyRealReasonWarningAndNoteMapsToItsCode() {
        for (text, code) in Self.everything {
            #expect(OutcomeReason.classify(text) == code, "\(text)")
        }
    }

    @Test func nothingTheAppWritesBecomesOther() {
        for (text, _) in Self.everything { #expect(OutcomeReason.classify(text) != .other, "\(text)") }
    }

    @Test func everyCodeIsReachedFromARealSourceExceptOther() {
        let reached = Set(Self.everything.map { OutcomeReason.classify($0.0) })
        let missing = Set(OutcomeReason.allCases).subtracting(reached).subtracting([.other])
        #expect(missing.isEmpty, "no real source reaches \(missing.map(\.rawValue).sorted())")
        #expect(OutcomeReason.classify("A sentence nobody wrote a code for") == .other)
    }

    // MARK: Misleading file names

    private static let misleadingNames = [
        "Cancelled trip.mov", "Holiday albums.mov", "Already small.mov", "Free space.mov",
        "Photos library isn't allowed.mov",
        "Recently deleted.mov", "Original changed during conversion.mov", "Couldn't be converted.mov",
        "Spatial video.mov",
    ]

    @Test func aFileNameCannotDecideTheCategory() {
        for name in Self.misleadingNames {
            let source = URL(filePath: "/x/\(name)")
            let stem = source.deletingPathExtension().lastPathComponent
            let output = URL(filePath: "/x/\(stem) (smaller).mov")
            let target = URL(filePath: "/x/\(stem).mp4")
            let names = [source.lastPathComponent, output.lastPathComponent, target.lastPathComponent]
            let renamed = DownscaleRunner.renamedNote(output: output, target: target, why: "already exists")
            #expect(OutcomeReason.classify(renamed, removing: names) == .nameChanged, "\(name)")
            let container = DownscaleRunner.containerNote(
                source: URL(filePath: "/x/\(stem).mp4"), pathExtension: "mov")
            #expect(OutcomeReason.classify(container, removing: names) == .containerChanged, "\(name)")
            // A message that names the file in its own words, as a runner might.
            // (A file named exactly like the reason can't be told from the reason; that stays "other", which is safe.)
            guard stem.lowercased() != DownscalePlanner.alreadySmallReason.lowercased() else { continue }
            let reason = "\(DownscalePlanner.alreadySmallReason): \(source.lastPathComponent)"
            #expect(OutcomeReason.classify(reason, removing: names) == .alreadySmall, "\(name)")
        }
    }

    @Test func withoutRemovingTheNamesAMisleadingOneWouldHaveWon() {
        // The failure the removal prevents: this note is about a rename, but its name says "cancelled".
        let output = URL(filePath: "/x/Cancelled trip (smaller).mov")
        let target = URL(filePath: "/x/Cancelled trip.mp4")
        let note = DownscaleRunner.renamedNote(output: output, target: target, why: "already exists")
        #expect(
            OutcomeReason.classify(note, removing: [output.lastPathComponent, target.lastPathComponent]) == .nameChanged
        )
    }

    @Test func thePromptUsesTheJobsOwnNamesWhenItClassifies() {
        let source = URL(filePath: "/Users/jane/Cancelled trip.mov")
        let output = URL(filePath: "/Users/jane/Cancelled trip (smaller).mov")
        let target = URL(filePath: "/Users/jane/Cancelled trip.mp4")
        let note = DownscaleRunner.renamedNote(output: output, target: target, why: "already exists")
        let outcome = JobOutcome(
            output: output, bytesBefore: 10, bytesAfter: 5, report: MetadataReport(), replacedOriginal: false,
            notes: [note], source: source)
        let job = Job(
            toolID: DownscaleTool.toolID, source: source, sourceBookmark: Data(), settings: Data(),
            state: .completed(outcome))
        let prompt = OutcomeExplainer.prompt(job: job, outcome: outcome, report: outcome.report)
        #expect(prompt.contains("Note: \(OutcomeReason.nameChanged.sentence)"))
        #expect(!prompt.contains(OutcomeReason.cancelled.sentence))
        #expect(!prompt.contains("Cancelled"))
    }

    // MARK: Order

    @Test func theMostSpecificMatchWinsNotTheFirstRow() {
        // "Saved as … because …" matches the rename row too, but the container wording is longer and wins.
        let text = DownscaleRunner.containerNote(source: URL(filePath: "/x/a.mp4"), pathExtension: "mov")
        #expect(OutcomeReason.classify(text) == .containerChanged)
        // Two rows match; the longer phrase wins whichever comes first in the table.
        #expect(
            OutcomeReason.classify("The original was kept because its copy in the originals folder didn't match")
                == .originalKeptBackupFailed)
        #expect(OutcomeReason.classify("The original was kept because something else") == .originalKeptOtherReason)
    }

    @Test func classifyingIsDeterministic() {
        for (text, _) in Self.everything {
            let first = OutcomeReason.classify(text)
            for _ in 0..<5 { #expect(OutcomeReason.classify(text) == first) }
        }
    }
}
