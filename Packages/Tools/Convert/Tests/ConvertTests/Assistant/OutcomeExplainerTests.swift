import AppCore
import Convert
import Foundation
import MediaEngine
import Testing

@testable import Assistant

@Suite struct OutcomeExplainerTests {
    private static let source = URL(filePath: "/Users/jane/Holiday with Anna/Beach day with Anna.mov")
    private static let output = URL(filePath: "/Users/jane/Holiday with Anna/Beach day with Anna (smaller).mov")

    private func job(
        _ state: JobState, preset: Preset = .balanced, predicted: [String]? = ["Location"]
    ) -> Job {
        let settings = ConvertJobSettings(preset: preset, saveTo: .nextToOriginal, predictedLost: predicted)
        return Job(
            toolID: ConvertTool.toolID, source: Self.source, sourceBookmark: Data(),
            settings: (try? JSONEncoder().encode(settings)) ?? Data(), state: state)
    }

    private func item(_ name: String, value: String) -> MetadataItem {
        MetadataItem(key: "qt.\(name)", category: .location, displayName: name, value: value)
    }

    private func outcome(warnings: [String] = [], notes: [String] = []) -> JobOutcome {
        JobOutcome(
            output: Self.output, bytesBefore: 1_200_000_000, bytesAfter: 400_000_000,
            report: MetadataReport(
                kept: [item("Make", value: "Apple")],
                changed: [MetadataChange(key: "video.duration", displayName: "Duration", from: "10.0", to: "10.02")],
                lost: [item("Location", value: "37.7749,-122.4194")]),
            replacedOriginal: false, warnings: warnings, notes: notes, source: Self.source)
    }

    // MARK: Prompt

    @Test func promptHasOnlyAllowedFields() {
        let outcome = outcome(
            warnings: ["Location was lost from /Users/jane/Holiday with Anna/Beach day with Anna.mov"],
            notes: ["Saved as QuickTime because Beach day with Anna.mov isn't MPEG-4 compatible"])
        let prompt = OutcomeExplainer.prompt(
            job: job(.completed(outcome)), outcome: outcome, report: outcome.report)
        for expected in ["Balanced", "Location", "Duration", "1.2 GB", "400 MB", "completed with warnings"] {
            #expect(prompt.localizedCaseInsensitiveContains(expected), "missing \(expected)")
        }
        for secret in ["Anna", "jane", "Holiday", "37.77", "122.41", "Apple", "/Users", ".mov", "QuickTime"] {
            #expect(!prompt.contains(secret), "leaked \(secret)")
        }
    }

    @Test func keptAsIsAndFailedPromptsCarryAReasonCodeNotTheReasonText() {
        let text = "Couldn't read /Users/jane/Holiday with Anna/Beach day with Anna.mov: Already small"
        for state in [JobState.keptAsIs(reason: text, code: .alreadySmall), .failed(reason: text, code: .alreadySmall)]
        {
            let prompt = OutcomeExplainer.prompt(job: job(state), outcome: nil, report: nil)
            #expect(prompt.contains("Reason: \(OutcomeCode.alreadySmall.sentence)"))
            for secret in ["Anna", "jane", "Holiday", "/Users", ".mov", "Couldn"] {
                #expect(!prompt.contains(secret), "leaked \(secret)")
            }
        }
        #expect(
            OutcomeExplainer.prompt(job: job(.keptAsIs(reason: "x")), outcome: nil, report: nil)
                .localizedCaseInsensitiveContains("kept as is"))
        #expect(
            OutcomeExplainer.prompt(job: job(.failed(reason: "x")), outcome: nil, report: nil)
                .contains("Reason: \(OutcomeCode.other.sentence)"))
    }

    @Test func aJobWhoseReasonsNameAFileAFolderAndAPathProducesAPromptWithNoneOfThem() {
        let folder = "Holiday with Anna"
        let name = "Beach day with Anna.mov"
        let path = "/Users/jane/\(folder)/\(name)"
        let warnings = [
            "Saved as \u{201C}\(name)\u{201D} because \u{201C}\(name) 2\u{201D} already exists",
            "The original was kept because \(path) couldn't be copied to the originals folder \(folder)",
            "\(folder) changed from \(path) to somewhere else",
            "Extended attribute \(folder) is lost",
        ]
        let outcome = outcome(warnings: warnings, notes: [path, "Saved as \(name) \(folder)"])
        for state in [JobState.completed(outcome), .keptAsIs(reason: path), .failed(reason: "\(folder): \(path)")] {
            let prompt = OutcomeExplainer.prompt(job: job(state), outcome: outcome, report: outcome.report)
            for secret in ["Anna", "Holiday", "Beach", "jane", "/Users", ".mov", folder, name, path] {
                #expect(!prompt.contains(secret), "leaked \(secret) in \(state)")
            }
        }
    }

    @Test func metadataNamesFromTheFileNeverReachThePrompt() {
        let report = MetadataReport(
            kept: [],
            changed: [
                MetadataChange(key: "qt.com.example.secret-plan", displayName: "secret-plan", from: "a", to: "b")
            ],
            lost: [
                MetadataItem(
                    key: "fs.xattr.com.example.Trip to Anna", category: .fileSystem,
                    displayName: "Extended attribute com.example.Trip to Anna", value: "hash"),
                MetadataItem(key: "qt.uiso/loci", category: .location, displayName: "Location", value: "37.7,-122.4"),
            ])
        let outcome = JobOutcome(
            output: Self.output, bytesBefore: 10, bytesAfter: 5, report: report, replacedOriginal: false)
        let prompt = OutcomeExplainer.prompt(job: job(.completed(outcome)), outcome: outcome, report: report)
        #expect(prompt.contains("Actual losses: Extended attribute, Location"))
        #expect(prompt.contains("Changed: Other metadata"))
        for secret in ["Anna", "secret", "example", "37.7"] { #expect(!prompt.contains(secret), "leaked \(secret)") }
    }

    @Test func customSettingsAreShownAsResolutionAndCodecLabels() {
        let settings = ConvertJobSettings(
            preset: .high, saveTo: .nextToOriginal,
            custom: DownscaleSpec(
                targetShortSide: 720, averageBitRate: 4_000_000, maxFrameRate: 30, codec: .h264Compatible))
        let job = Job(
            toolID: ConvertTool.toolID, source: Self.source, sourceBookmark: Data(),
            settings: (try? JSONEncoder().encode(settings)) ?? Data(), state: .failed(reason: "x"))
        let prompt = OutcomeExplainer.prompt(job: job, outcome: nil, report: nil)
        for line in [
            "Preset: Custom settings", "Resolution: 720p short side", "Codec: H.264 (SDR)", "capped at 30 fps",
        ] {
            #expect(prompt.contains(line), "missing \(line)")
        }
    }

    @Test func predictedAndActualLossesAreBothThere() {
        let outcome = outcome()
        let prompt = OutcomeExplainer.prompt(
            job: job(.completed(outcome), predicted: ["Location", "Camera make", "Trip to Anna"]), outcome: outcome,
            report: outcome.report)
        #expect(prompt.contains("Predicted losses: Location, Camera make, Other metadata"))
        #expect(!prompt.contains("Anna"))
        #expect(prompt.contains("Actual losses: Location"))
    }

    // MARK: Explaining

    @Test func explanationComesFromTheModelWithTheJobsFactsInThePrompt() async {
        let outcome = outcome(warnings: ["Location was lost"])
        let client = FakeLanguageModelClient(returning: "  Location was lost because the format can't hold it.  ")
        let text = await OutcomeExplainer(client: client).explain(
            job: job(.completed(outcome)), outcome: outcome, report: outcome.report)
        #expect(text == "Location was lost because the format can't hold it.")
        #expect(client.prompts.count == 1)
        #expect(client.prompts[0].contains("Actual losses: Location"))
        #expect(client.instructions[0].contains("sentences"))
    }

    @Test func errorsFallBackToTheExistingText() async {
        let outcome = outcome(warnings: ["Location was lost"], notes: ["Saved as QuickTime"])
        let failing = FakeLanguageModelClient { _, _ in throw AssistantError.guardrail }
        let explainer = OutcomeExplainer(client: failing)
        let completed = await explainer.explanation(
            job: job(.completed(outcome)), outcome: outcome, report: outcome.report)
        #expect(!completed.isGenerated)
        #expect(completed.text == "Location was lost Saved as QuickTime")
        let kept = await explainer.explanation(job: job(.keptAsIs(reason: "Already small")), outcome: nil, report: nil)
        #expect(kept.text == "Already small")
        let failed = await explainer.explanation(job: job(.failed(reason: "Disk full")), outcome: nil, report: nil)
        #expect(failed.text == "Disk full")
    }

    @Test func aStuckModelFallsBackAfterTheTimeout() async {
        let client = FakeLanguageModelClient { _, _ in try await hangForever() }
        let explainer = OutcomeExplainer(client: client, timeout: .milliseconds(100))
        let text = await explainer.explain(job: job(.failed(reason: "Disk full")), outcome: nil, report: nil)
        #expect(text == "Disk full")
    }

    @Test func emptyAnswersFallBack() async {
        let client = FakeLanguageModelClient(returning: "   ")
        let text = await OutcomeExplainer(client: client).explain(
            job: job(.failed(reason: "Disk full")), outcome: nil, report: nil)
        #expect(text == "Disk full")
    }

    // MARK: Cache

    @MainActor
    @Test func explanationsAreCachedPerJob() async {
        let client = FakeLanguageModelClient(returning: "Because.")
        let explanations = OutcomeExplanations(explainer: OutcomeExplainer(client: client))
        let job = job(.failed(reason: "Disk full"))
        let first = await explanations.explain(job: job, outcome: nil)
        let second = await explanations.explain(job: job, outcome: nil)
        #expect(first == "Because." && second == "Because.")
        #expect(client.callCount == 1)
        #expect(explanations.cached(for: job.id) == "Because.")
        let other = self.job(.failed(reason: "Disk full"))
        _ = await explanations.explain(job: other, outcome: nil)
        #expect(client.callCount == 2)
    }

    @MainActor
    @Test func fallbackTextIsNotCachedSoALaterTryCanSucceed() async {
        let client = FakeLanguageModelClient { _, _ in throw AssistantError.rateLimited }
        let explanations = OutcomeExplanations(explainer: OutcomeExplainer(client: client))
        let job = job(.failed(reason: "Disk full"))
        let text = await explanations.explain(job: job, outcome: nil)
        #expect(text == "Disk full")
        #expect(explanations.cached(for: job.id) == nil)
        _ = await explanations.explain(job: job, outcome: nil)
        #expect(client.callCount == 2)
    }

    @MainActor
    @Test func aJobThatChangedIsExplainedAgain() async {
        let client = FakeLanguageModelClient(returning: "Because.")
        let explanations = OutcomeExplanations(explainer: OutcomeExplainer(client: client))
        var job = job(.failed(reason: "Disk full", code: .notEnoughSpace))
        _ = await explanations.explain(job: job, outcome: nil)
        job.state = .failed(reason: "Already small", code: .alreadySmall)
        _ = await explanations.explain(job: job, outcome: nil)
        #expect(client.callCount == 2)
    }

    // MARK: Real model

    @Test(.enabled(if: SystemLanguageModelClient().isAvailable), .timeLimit(.minutes(1)))
    func realModelExplainsAKeptAsIsVideo() async {
        let explainer = OutcomeExplainer(client: SystemLanguageModelClient(), timeout: .seconds(30))
        let explanation = await explainer.explanation(
            job: job(.keptAsIs(reason: "It is already small, so converting would not save space")),
            outcome: nil, report: nil)
        #expect(!explanation.text.isEmpty)
    }
}
