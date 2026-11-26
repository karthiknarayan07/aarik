import AppCore
import AppUI
import Assistant
import Foundation
import LocalLibrary
import PhotosLibrary

/// What Convert adds to the Ask tab: tools that read freely (search the library, estimate savings, explain a
/// result, list the queue) and tools that act (queue conversions, pause or resume, move originals), which the chat
/// only runs after a tap on a confirmation card. Replace Originals still ends in Photos' own confirmation.
public struct ConvertAssistantToolProvider: AssistantToolProvider {
    private let context: ConvertAssistantContext

    @MainActor public init(model: ConvertModel, now: @escaping @Sendable () -> Date = { .now }) {
        context = ConvertAssistantContext(model: model, now: now)
    }

    public func assistantTools() -> [any AssistantTool] {
        [
            SearchLibraryTool(context: context), EstimateSavingsTool(context: context),
            SavingsSoFarTool(context: context), ExplainOutcomeTool(context: context), ListQueueTool(context: context),
            ConvertVideosTool(context: context), PauseQueueTool(context: context), ResumeQueueTool(context: context),
            ReplaceOriginalsTool(context: context), PhotosAccessTool(context: context),
        ]
    }
}

/// The model, held weakly (the services own the provider, and the model owns the services).
@MainActor
final class ConvertAssistantContext {
    private weak var model: ConvertModel?
    private let now: @Sendable () -> Date

    init(model: ConvertModel, now: @escaping @Sendable () -> Date = { .now }) {
        self.model = model
        self.now = now
    }

    func model(or fail: String = "Convert isn't available.") throws -> ConvertModel {
        guard let model else { throw AssistantToolError(fail) }
        return model
    }

    /// How many items a tool result lists: enough to answer, short enough for the model's small context.
    static let listLimit = 8

    // MARK: Search

    func search(_ arguments: AssistantArguments) throws -> AssistantToolOutput {
        let model = try model()
        let scope = arguments.string("library")?.lowercased() ?? "any"
        var items: [LibraryItem] = []
        if scope != "files" { items += model.photos.items }
        if scope != "photos" { items += model.library.items }
        let words = Self.nameWords(arguments.string("name_contains"))
        let year = Self.year(arguments.string("year"), today: now())
        let minimum = Int64(arguments.integer("minimum_size_mb") ?? 0) * 1_000_000
        let matches = items.filter { item in
            let name = item.name.lowercased()
            if !words.allSatisfy(name.contains) { return false }
            if let year, item.captureDate.map({ Calendar.current.component(.year, from: $0) }) != year { return false }
            return item.byteSize >= minimum
        }.sorted { $0.byteSize > $1.byteSize }
        let shown = matches.prefix(Self.listLimit)
        let lines = shown.map { item in
            "\(item.name) · \(QualityBucket(item: item).title) · \(ByteFormat.string(item.byteSize))"
        }
        let total = ByteFormat.string(matches.reduce(0) { $0 + $1.byteSize })
        let access = photosAccessNote(model, scope: scope)
        var summary =
            items.isEmpty
            ? (access ?? "No videos found. The library is empty: nothing in Photos or Local Files yet.")
            : "No videos matched. The library has \(items.count.formatted()) videos; try again without the filters."
        if !matches.isEmpty {
            // Numbered, one per line: the model reads this as a list and repeats it by name.
            let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let more = matches.count - shown.count
            let found =
                matches.count == 1 ? "Found 1 video in total" : "Found \(matches.count.formatted()) videos in total"
            let listed =
                more > 0
                ? "\(shown.count.formatted()) are listed below, largest first."
                : (shown.count == 1
                    ? "It is listed below."
                    : "All \(shown.count) are listed below, largest first. Name every one of them.")
            summary =
                "\(found), \(total) combined\(Self.breakdown(matches)). \(listed)\n\(numbered)"
                + (more > 0 ? "\n\(more.formatted()) other videos aren't listed." : "")
            if let access { summary += "\n" + access }
        } else if let access, !items.isEmpty {
            summary += " " + access
        }
        return AssistantToolOutput(text: summary, title: "Searched Library", count: matches.count, lines: lines)
    }

    /// " (3 in Photos: 2 GB, 2 in Local Files: 1 GB)" when both sources are among the matches, else nothing.
    private static func breakdown(_ matches: [LibraryItem]) -> String {
        let photos = matches.filter { $0.photosIdentifier != nil }
        let files = matches.filter { $0.photosIdentifier == nil }
        guard !photos.isEmpty, !files.isEmpty else { return "" }
        let photoBytes = ByteFormat.string(photos.reduce(0) { $0 + $1.byteSize })
        let fileBytes = ByteFormat.string(files.reduce(0) { $0 + $1.byteSize })
        return " (\(photos.count) in Photos: \(photoBytes), \(files.count) in Local Files: \(fileBytes))"
    }

    /// Says Photos access is off, when it is and the search would have looked there.
    func photosAccessNote(_ model: ConvertModel, scope: String) -> String? {
        guard scope != "files", model.photos.isAuthorizationKnown else { return nil }
        switch model.photos.authorization {
        case .authorized, .limited: return nil
        case .notDetermined:
            return "Photos access hasn't been allowed yet, so videos in Photos can't be read. Say so, and offer to "
                + "ask for access with the allow_photos_access tool. Don't call the library empty."
        case .denied, .restricted:
            return "Photos access is turned off, so videos in Photos can't be read. Say so, and offer to open "
                + "Settings with the allow_photos_access tool. Don't call the library empty."
        }
    }

    /// A year from "2025", "this year", "last year" or "2 years ago", worked out from today's date.
    static func year(_ text: String?, today: Date) -> Int? {
        guard let text = text?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let current = Calendar.current.component(.year, from: today)
        if let number = Int(text) { return number >= 1900 ? number : nil }
        if let ago = text.split(separator: " ").compactMap({ Int($0) }).first, text.contains("ago") {
            return current - ago
        }
        if text.contains("this") || text.contains("current") { return current }
        if text.contains("last") || text.contains("previous") || text.contains("past") { return current - 1 }
        return text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first { $0 >= 1900 }
    }

    /// The words of a name filter that can narrow anything. "Biggest videos" says what the person wants, not what the
    /// files are called, so words about size and kind are dropped, and what is left must all appear in the name.
    static func nameWords(_ text: String?) -> [String] {
        let generic: Set<String> = [
            "video", "videos", "movie", "movies", "clip", "clips", "file", "files", "biggest", "largest", "big",
            "large", "my", "all", "the", "and", "of", "in", "on", "photos", "library",
        ]
        return (text ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !generic.contains($0) }
    }

    // MARK: Savings

    struct Analysis: Sendable {
        var buckets: [SavingsBucket]
        var undated: Int
    }

    func analysis() throws -> Analysis {
        let model = try model()
        let photos = model.photos.items
        let files = model.library.items
        let shrunk = model.shrunkIDs(in: model.browser)
        let buckets = SavingsAnalyzer.buckets(
            photos: photos, files: files, preset: model.preset, overrides: model.presetOverrides,
            custom: model.advanced.spec, shrunk: shrunk)
        let undated = SavingsAnalyzer.undatedCount(
            photos: photos, files: files, preset: model.preset, overrides: model.presetOverrides,
            custom: model.advanced.spec, shrunk: shrunk)
        // The same groups the queue action reads, so "Convert" later acts on what was just described.
        model.assistant.smartPicks.update(
            buckets: buckets, undatedCount: undated,
            key: buckets.map { "\($0.identity)-\($0.count)-\($0.couldFree)" })
        return Analysis(buckets: buckets, undated: undated)
    }

    func estimate() throws -> AssistantToolOutput {
        let analysis = try analysis()
        let total = analysis.buckets.reduce(Int64(0)) { $0 + $1.couldFree }
        let top = analysis.buckets.prefix(Self.listLimit)
        let lines = top.map { "\($0.id): \($0.title) · \($0.detail)" }
        let videos = analysis.buckets.reduce(0) { $0 + $1.count }
        let librarySize =
            try model().photos.items.reduce(Int64(0)) { $0 + $1.byteSize }
            + model().library.items.reduce(Int64(0)) { $0 + $1.byteSize }
        let text =
            analysis.buckets.isEmpty
            ? "Nothing in the library would free space."
            : "The library takes \(ByteFormat.string(librarySize)) in total. "
                + "Converting everything could free about \(ByteFormat.string(total)) across \(videos.formatted()) videos. "
                + "Biggest groups, most savings first:\n" + lines.joined(separator: "\n")
        return AssistantToolOutput(text: text, title: "Estimated Savings", count: analysis.buckets.count, lines: lines)
    }

    // MARK: Saved so far

    func savedSoFar() async throws -> AssistantToolOutput {
        let model = try model()
        let cache = model.services.savingsStats
        if !cache.hasLoaded { await cache.load() }
        let outcomes = model.completedJobs.map(\.outcome)
        let live = outcomes.reduce(Int64(0)) { $0 + max(0, $1.bytesBefore - $1.bytesAfter) }
        let stored = cache.snapshot
        let saved = max(live, stored?.savedBytes ?? 0)
        let converted = max(outcomes.count, stored?.conversions ?? 0)
        let couldFree = try analysis().buckets.reduce(Int64(0)) { $0 + $1.couldFree }
        let text =
            converted == 0
            ? "Nothing has been converted yet, so nothing has been saved so far. "
                + "Converting everything could free about \(ByteFormat.string(couldFree)) now."
            : "Saved so far: \(ByteFormat.string(saved)) across \(converted.formatted()) converted videos. "
                + "Converting the rest could free about \(ByteFormat.string(couldFree)) more now."
        let lines = [
            "Saved so far · \(ByteFormat.string(saved))", "Videos converted · \(converted.formatted())",
            "Could free now · \(ByteFormat.string(couldFree))",
        ]
        return AssistantToolOutput(text: text, title: "Checked Savings", count: converted, lines: lines)
    }

    // MARK: Photos access

    func accessConfirmation() throws -> AssistantConfirmation {
        let model = try model()
        switch model.photos.authorization {
        case .authorized: throw AssistantToolError("Photos access is already on.")
        case .limited:
            return AssistantConfirmation(
                title: "Open Settings",
                message: "Photos access is limited to the videos you picked. Settings lets you share more.",
                confirmLabel: "Open Settings")
        case .notDetermined:
            return AssistantConfirmation(
                title: "Allow Access to Photos",
                message: "Shows the system prompt so the app can read your Photos videos. Nothing is changed.",
                confirmLabel: "Continue")
        case .denied, .restricted:
            return AssistantConfirmation(
                title: "Open Settings", message: "Photos access is off. Settings lets you turn it on.",
                confirmLabel: "Open Settings")
        }
    }

    func requestAccess() async throws -> AssistantToolOutput {
        let model = try model()
        _ = try accessConfirmation()
        if model.photos.authorization == .notDetermined {
            await model.photos.requestAccess()
            let on = model.photos.authorization.allowsReading
            return AssistantToolOutput(
                text: on
                    ? "Photos access is on; \(model.photos.items.count.formatted()) videos can be read now."
                    : "Photos access was not given.",
                title: "Asked for Photos Access")
        }
        model.openPhotosAccessSettings()
        return AssistantToolOutput(
            text: "Settings is open. The person can turn on Photos access there.", title: "Opened Settings")
    }

    // MARK: Results and queue

    func explain(_ arguments: AssistantArguments) throws -> AssistantToolOutput {
        let model = try model()
        let name = arguments.string("video_name")?.lowercased()
        let finished = model.jobs.reversed().filter { job in
            switch job.state {
            case .completed, .keptAsIs, .failed: true
            case .queued, .running: false
            }
        }
        guard
            let job = finished.first(where: { name == nil || $0.source.lastPathComponent.lowercased().contains(name!) })
        else { throw AssistantToolError("No finished conversion matches.") }
        var outcome: JobOutcome?
        if case .completed(let done) = job.state { outcome = done }
        let facts = OutcomeExplainer.prompt(job: job, outcome: outcome, report: nil)
        return AssistantToolOutput(
            text: facts, title: "Checked Result", lines: facts.split(separator: "\n").map(String.init))
    }

    func listQueue() throws -> AssistantToolOutput {
        let model = try model()
        let pending = model.queuedJobs
        let lines = pending.prefix(Self.listLimit).map { job -> String in
            let state: String
            if case .running(let progress) = job.state {
                state = "converting, \(Int(progress * 100))%"
            } else {
                state = "waiting"
            }
            return "\(job.source.lastPathComponent) · \(state)"
        }
        let status = model.isQueuePaused ? "The queue is paused. " : ""
        let text =
            pending.isEmpty
            ? status + "The queue is empty."
            : status + "\(pending.count) in the queue, first \(lines.count):\n" + lines.joined(separator: "\n")
        return AssistantToolOutput(text: text, title: "Listed Queue", count: pending.count, lines: lines)
    }

    // MARK: Actions

    func convertConfirmation(_ arguments: AssistantArguments) throws -> (AssistantConfirmation, SavingsBucket) {
        let bucket = try chooseBucket(arguments)
        guard try model().canAddToQueue(bucket) else {
            throw AssistantToolError(
                "There is nowhere to save the copies yet. Choose a save location in Convert first.")
        }
        let videos = bucket.count == 1 ? "1 Video" : "\(bucket.count) Videos"
        return (
            AssistantConfirmation(
                title: "Convert \(videos)",
                message: "\(bucket.title). Save about \(ByteFormat.string(bucket.couldFree))?",
                confirmLabel: "Convert"), bucket
        )
    }

    private func chooseBucket(_ arguments: AssistantArguments) throws -> SavingsBucket {
        let buckets = try analysis().buckets
        guard !buckets.isEmpty else { throw AssistantToolError("Nothing in the library would free space.") }
        if let id = arguments.string("group")?.uppercased() {
            guard let bucket = buckets.first(where: { $0.id == id }) else {
                throw AssistantToolError("There is no group \(id). Use a group id from the savings estimate.")
            }
            return bucket
        }
        return buckets[0]
    }

    func convert(_ arguments: AssistantArguments) throws -> AssistantToolOutput {
        let model = try model()
        let (_, bucket) = try convertConfirmation(arguments)
        model.addToQueue(bucket)
        let videos = bucket.count == 1 ? "1 video" : "\(bucket.count) videos"
        let review =
            model.isConfirmingReplace
            ? " Convert is asking to confirm Replace; finish that in the Convert tab." : ""
        return AssistantToolOutput(
            text:
                "Started adding \(videos) to the queue. If Convert needs a review of lost metadata, it asks in the Convert tab."
                + review,
            title: "Queued Videos", count: bucket.count)
    }

    func pauseConfirmation(pause: Bool) throws -> AssistantConfirmation {
        let model = try model()
        if pause {
            guard !model.isQueuePaused else { throw AssistantToolError("The queue is already paused.") }
            return AssistantConfirmation(
                title: "Pause the Queue", message: "Converting stops after the current video's progress is saved.",
                confirmLabel: "Pause")
        }
        guard model.isQueuePaused else { throw AssistantToolError("The queue isn't paused.") }
        return AssistantConfirmation(
            title: "Resume the Queue", message: "\(model.queuedJobs.count) waiting.", confirmLabel: "Resume")
    }

    func setPaused(_ pause: Bool) throws -> AssistantToolOutput {
        let model = try model()
        if model.isQueuePaused != pause { model.toggleQueuePaused() }
        return AssistantToolOutput(
            text: pause ? "The queue is paused." : "The queue is running.",
            title: pause ? "Paused Queue" : "Resumed Queue")
    }

    func originalsConfirmation() throws -> AssistantConfirmation {
        let model = try model()
        guard model.isForeground else {
            throw AssistantToolError("Open the app first; Photos asks in the foreground only.")
        }
        let ready = model.pendingOriginals.filter { $0.blocked == nil }.count
        guard ready > 0 else { throw AssistantToolError("No originals are waiting to be moved.") }
        let originals = ready == 1 ? "1 Original" : "\(ready) Originals"
        return AssistantConfirmation(
            title: "Replace \(originals)",
            message: "They move to Recently Deleted after Photos asks you to confirm.", confirmLabel: "Continue")
    }

    func moveOriginals() throws -> AssistantToolOutput {
        let model = try model()
        _ = try originalsConfirmation()
        model.moveOriginalsToRecentlyDeleted()
        return AssistantToolOutput(
            text: "Photos is asking the person to confirm. Nothing is deleted unless they do.", title: "Asked Photos")
    }
}

// MARK: Tools

private struct SearchLibraryTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "search_library" }
    var summary: String {
        "Looks up videos, and answers how many there are and how much space they take. The first line is the "
            + "count and total size of what matched: use it for any count or size question. With library any it "
            + "covers the whole library. Then it lists the biggest by name and size. Every argument is optional: "
            + "leave out any the person didn't say."
    }
    var parameters: [AssistantParameter] {
        [
            AssistantParameter(
                "name_contains",
                "Only if the person gave a word from a video's name, such as a place or event. Leave empty for "
                    + "words like biggest, videos, all or my."),
            AssistantParameter(
                "year",
                "Only if the person named a year or said this year or last year (write exactly that, or the "
                    + "four-digit year). Otherwise leave empty."),
            AssistantParameter(
                "minimum_size_mb",
                "Only if the person gave a size such as over 100 MB. Leave empty for biggest or large.",
                kind: .integer),
            AssistantParameter(
                "library", "photos, files, or any (both). Use any unless the person said Photos or Local Files.",
                allowed: ["photos", "files", "any"]),
        ]
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput {
        try await context.search(arguments)
    }
}

private struct EstimateSavingsTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "estimate_savings" }
    var summary: String {
        "Estimates how much space converting could free in total and by group of videos, each with an id like B1."
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput { try await context.estimate() }
}

private struct ExplainOutcomeTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "explain_outcome" }
    var summary: String {
        "Gets the facts about why a finished conversion was kept as is, failed or completed with warnings."
    }
    var parameters: [AssistantParameter] {
        [AssistantParameter("video_name", "Part of the video's file name. Leave empty for the most recent.")]
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput {
        try await context.explain(arguments)
    }
}

private struct ListQueueTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "list_queue" }
    var summary: String { "Lists the videos waiting or converting, and whether the queue is paused." }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput { try await context.listQueue() }
}

private struct ConvertVideosTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "convert_videos" }
    var summary: String {
        "Queues a group of videos for conversion after the person confirms. Call estimate_savings first for group ids."
    }
    var requiresConfirmation: Bool { true }
    var parameters: [AssistantParameter] {
        [AssistantParameter("group", "A group id from estimate_savings, such as B1. Empty means the biggest group.")]
    }
    func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
        try await context.convertConfirmation(arguments).0
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput {
        try await context.convert(arguments)
    }
}

private struct PauseQueueTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "pause_queue" }
    var summary: String { "Pauses converting after the person confirms." }
    var requiresConfirmation: Bool { true }
    func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
        try await context.pauseConfirmation(pause: true)
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput { try await context.setPaused(true) }
}

private struct ResumeQueueTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "resume_queue" }
    var summary: String { "Resumes converting after the person confirms." }
    var requiresConfirmation: Bool { true }
    func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
        try await context.pauseConfirmation(pause: false)
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput { try await context.setPaused(false) }
}

private struct ReplaceOriginalsTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "replace_originals" }
    var summary: String {
        "Moves the Photos originals of finished conversions to Recently Deleted. The person confirms here, then Photos asks again."
    }
    var requiresConfirmation: Bool { true }
    func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
        try await context.originalsConfirmation()
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput { try await context.moveOriginals() }
}

private struct SavingsSoFarTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "savings_so_far" }
    var summary: String {
        "Says how much space has been saved so far by finished conversions, how many videos were converted, and how "
            + "much more converting could free now. Use it for how much have I saved."
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput {
        try await context.savedSoFar()
    }
}

private struct PhotosAccessTool: AssistantTool {
    let context: ConvertAssistantContext
    var name: String { "allow_photos_access" }
    var summary: String {
        "Asks for access to Photos, or opens Settings to turn it on, after the person confirms. Offer it only when a "
            + "tool says Photos access is off."
    }
    var requiresConfirmation: Bool { true }
    func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
        try await context.accessConfirmation()
    }
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput {
        try await context.requestAccess()
    }
}
