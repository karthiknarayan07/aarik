import AppCore
import DownscaleVideo
import Foundation
import Testing

@testable import Assistant

@Suite struct OutcomeExplainerTests {
    private static let source = URL(filePath: "/Users/jane/Holiday with Anna/Beach day with Anna.mov")
    private static let output = URL(filePath: "/Users/jane/Holiday with Anna/Beach day with Anna (smaller).mov")

    private func job(
        _ state: JobState, preset: Preset = .balanced, predicted: [String]? = ["Location"]
    ) -> Job {
        let settings = DownscaleJobSettings(preset: preset, saveTo: .nextToOriginal, predictedLost: predicted)
        return Job(
            toolID: DownscaleTool.toolID, source: Self.source, sourceBookmark: Data(),
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
                changed: [MetadataChange(key: "k", displayName: "Duration", from: "10.0", to: "10.02")],
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
        for secret in ["Anna", "jane", "Holiday", "37.77", "122.41", "Apple", "/Users", ".mov"] {
            #expect(!prompt.contains(secret), "leaked \(secret)")
        }
    }

    @Test func keptAsIsAndFailedPromptsCarryTheRedactedReasonOnly() {
        let reason = "Couldn't read /Users/jane/Holiday with Anna/Beach day with Anna.mov: no video track"
        for state in [JobState.keptAsIs(reason: reason), .failed(reason: reason)] {
            let prompt = OutcomeExplainer.prompt(job: job(state), outcome: nil, report: nil)
            #expect(prompt.contains("no video track"))
            for secret in ["Anna", "jane", "/Users", ".mov"] { #expect(!prompt.contains(secret)) }
        }
        #expect(
            OutcomeExplainer.prompt(job: job(.keptAsIs(reason: "x")), outcome: nil, report: nil)
                .localizedCaseInsensitiveContains("kept as is"))
        #expect(
            OutcomeExplainer.prompt(job: job(.failed(reason: "x")), outcome: nil, report: nil)
                .localizedCaseInsensitiveContains("failed"))
    }

    @Test func predictedAndActualLossesAreBothThere() {
        let outcome = outcome()
        let prompt = OutcomeExplainer.prompt(
            job: job(.completed(outcome), predicted: ["Location", "Camera"]), outcome: outcome, report: outcome.report)
        #expect(prompt.contains("Predicted losses: Location, Camera"))
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
        #expect(client.prompts[0].contains("Location was lost"))
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
        var job = job(.failed(reason: "Disk full"))
        _ = await explanations.explain(job: job, outcome: nil)
        job.state = .failed(reason: "Out of memory")
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
