import AppCore
import AppServices
import AppUI
import CoreGraphics
import Foundation
import LocalLibrary
import MediaTestSupport
import PhotosLibrary
import Testing

@testable import Assistant
@testable import Convert

/// Everyday phrasing against the REAL on-device model (Foundation Models, on the Mac as well as the iPhone): fifteen
/// natural questions, each asked of a fixture library that has Local Files only, Photos only, and both. It checks facts,
/// never wording: that the right tool ran with the right scope, that the tool's count is the fixture's truth, that the
/// answer names the video or the count the fixture says, and that nothing acts without a confirmation.
///
/// This is the package-level sibling of the iOS UI test `RealAssistantSmokeTests` (Apps/iOS/UITests), which drives the
/// same model through the iPhone's Ask tab. Slow and dependent on the machine, so it runs only with `RUN_REAL_AI=1`:
///
///     cd Packages/Tools/Convert && RUN_REAL_AI=1 swift test --filter RealAssistantEverydayPhrasingTests
///
/// Every failed case is reported on its own with the answer the model gave, and the run ends with a
/// `REAL-AI-EVAL pass rate` line. The model isn't deterministic, so a failure here is a finding to read, not a
/// reason to rerun until green.
@MainActor
@Suite(.serialized) struct RealAssistantEverydayPhrasingTests {
    // MARK: Fixture

    enum Library: String, CaseIterable {
        case filesOnly = "Local Files only"
        case photosOnly = "Photos only"
        case both = "Photos and Local Files"

        var hasFiles: Bool { self != .photosOnly }
        var hasPhotos: Bool { self != .filesOnly }
    }

    private static func date(year: Int, month: Int = 6) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))!
    }

    private static func photo(_ id: String, _ name: String, megabytes: Int64, year: Int) -> PhotoAsset {
        let created = date(year: year)
        return PhotoAsset(
            id: id, creationDate: created, location: nil, pixelSize: CGSize(width: 3840, height: 2160),
            duration: 30, originalFileName: name, originalByteSize: megabytes * 1_000_000, modificationDate: created)
    }

    private static var photoAssets: [PhotoAsset] {
        let thisYear = Calendar.current.component(.year, from: .now)
        return [
            photo("A/L0/001", "Beach Day.MOV", megabytes: 900, year: thisYear - 1),
            photo("B/L0/001", "Birthday Dinner.MOV", megabytes: 600, year: thisYear - 1),
            photo("C/L0/001", "Hike Summit.MOV", megabytes: 1200, year: thisYear - 2),
            photo("D/L0/001", "Fireworks.MOV", megabytes: 450, year: thisYear - 2),
            photo("E/L0/001", "Sunset Walk.MOV", megabytes: 80, year: thisYear),
            photo("F/L0/001", "Beach Sunset.MOV", megabytes: 300, year: thisYear - 1),
        ]
    }

    /// The model, its Photos library (fake) and Local Files (real clips, one made 150 MB), ready to be asked about.
    @MainActor private struct Rig {
        let model: ConvertModel
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
        var items: [LibraryItem] { model.photos.items + model.library.items }
    }

    private static func makeRig(_ library: Library, clip: URL) async throws -> Rig {
        let directory = URL.temporaryDirectory.appending(
            path: "real-ai-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = UserDefaults(suiteName: "RealAssistantEverydayPhrasingTests-\(UUID().uuidString)")!
        let store = FakePhotoStore(assets: library.hasPhotos ? photoAssets : [])
        let services = AppServices(directory: directory, defaults: suite, photoStore: store)
        let model = ConvertModel(services: services)
        await model.photos.start()
        await model.photos.waitUntilIdle()
        if library.hasFiles {
            var files: [URL] = []
            for name in ["Local Wedding.mov", "Local Road Trip.mov", "Local Hike Notes.mov"] {
                let file = directory.appending(path: name)
                try FileManager.default.copyItem(at: clip, to: file)
                files.append(file)
            }
            // One of them is big: padding after the movie data keeps it a readable movie.
            let handle = try FileHandle(forWritingTo: files[1])
            try handle.truncate(atOffset: 150_000_000)
            try handle.close()
            model.library.add(files)
            await model.library.waitUntilIdle()
        }
        return Rig(model: model, directory: directory)
    }

    // MARK: Questions

    /// What the fixture says is true, worked out from the library's own items (not from any tool).
    private struct Truth {
        let items: [LibraryItem]
        let photos: [LibraryItem]
        let files: [LibraryItem]
        let lastYear: Int

        var biggest: LibraryItem? { items.max { $0.byteSize < $1.byteSize } }
        func count(minimumMB: Int64) -> Int { items.filter { $0.byteSize >= minimumMB * 1_000_000 }.count }
        func count(year: Int) -> Int {
            items.filter { $0.captureDate.map { Calendar.current.component(.year, from: $0) } == year }.count
        }
        func items(named word: String) -> [LibraryItem] {
            items.filter { $0.name.localizedCaseInsensitiveContains(word) }
        }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteSize } }
    }

    /// What the chat showed for one question.
    private struct Outcome {
        let answer: String
        let calls: [ChatToolCall]
        let sawConfirmation: Bool
        let jobsAfter: Int

        func called(_ names: Set<String>) -> Bool { calls.contains { names.contains($0.toolName) } }
        func lastCall(_ name: String) -> ChatToolCall? { calls.last { $0.toolName == name } }
    }

    private struct Question {
        let text: String
        /// Returns what is wrong with the outcome, or nothing.
        let judge: @MainActor (Truth, Outcome) -> [String]
    }

    private static let search = "search_library"

    /// The number as digits (not inside a longer number) or as a word.
    private static func mentions(_ number: Int, in text: String) -> Bool {
        let words = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        ]
        let pattern = "(?<![0-9.])\(number)(?![0-9])"
        if text.range(of: pattern, options: .regularExpression) != nil { return true }
        return number < words.count
            && text.range(of: "\\b\(words[number])\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func mentionsName(_ item: LibraryItem, in text: String) -> Bool {
        let stem = (item.name as NSString).deletingPathExtension
        return text.localizedCaseInsensitiveContains(stem)
    }

    /// The search-tool row's count must be the truth, and the answer must say it (when it is not zero).
    private static func searchCount(_ expected: Int, _ outcome: Outcome, saysCount: Bool = true) -> [String] {
        guard let call = outcome.lastCall(search) else { return ["search_library was never called"] }
        var problems: [String] = []
        if call.count != expected {
            problems.append("the search found \(call.count ?? -1), the fixture has \(expected)")
        }
        if saysCount, expected > 0, !mentions(expected, in: outcome.answer) {
            problems.append("the answer never says \(expected)")
        }
        return problems
    }

    private static let questions: [Question] = [
        Question(text: "find my biggest videos") { truth, outcome in
            guard let biggest = truth.biggest else {
                return outcome.called([search]) ? [] : ["search_library was never called"]
            }
            var problems = outcome.called([search]) ? [] : ["search_library was never called"]
            if !mentionsName(biggest, in: outcome.answer) { problems.append("the answer never names \(biggest.name)") }
            return problems
        },
        Question(text: "what can I free up") { truth, outcome in
            guard outcome.called(["estimate_savings"]) else { return ["estimate_savings was never called"] }
            return []
        },
        Question(text: "videos from last year") { truth, outcome in
            searchCount(truth.count(year: truth.lastYear), outcome)
        },
        Question(text: "anything over 100 MB") { truth, outcome in
            searchCount(truth.count(minimumMB: 100), outcome)
        },
        Question(text: "how much have I saved") { truth, outcome in
            // Nothing has been converted, so no figure may be claimed as saved; any read-only tool is a fair way in.
            var problems: [String] = []
            if outcome.calls.isEmpty { problems.append("no tool was called") }
            if outcome.sawConfirmation { problems.append("a confirmation card appeared for a question") }
            if outcome.answer.range(of: "saved (about )?[0-9]", options: [.regularExpression, .caseInsensitive]) != nil
            {
                problems.append("the answer claims a figure was saved; nothing was converted")
            }
            return problems
        },
        Question(text: "how many videos do I have") { truth, outcome in
            searchCount(truth.items.count, outcome)
        },
        Question(text: "do I have anything from the beach") { truth, outcome in
            var problems = searchCount(truth.items(named: "beach").count, outcome, saysCount: false)
            for item in truth.items(named: "beach") where !mentionsName(item, in: outcome.answer) {
                problems.append("the answer never names \(item.name)")
            }
            return problems
        },
        Question(text: "show me my videos in Photos") { truth, outcome in
            searchCount(truth.photos.count, outcome, saysCount: false)
        },
        Question(text: "what's in my Local Files") { truth, outcome in
            searchCount(truth.files.count, outcome, saysCount: false)
        },
        Question(text: "what's in the queue") { truth, outcome in
            var problems = outcome.called(["list_queue"]) ? [] : ["list_queue was never called"]
            let empty = ["empty", "nothing", "no videos", "isn't", "not"].contains {
                outcome.answer.localizedCaseInsensitiveContains($0)
            }
            if !empty { problems.append("the answer doesn't say the queue is empty") }
            return problems
        },
        Question(text: "what's my biggest video from \(Calendar.current.component(.year, from: .now) - 2)") {
            truth, outcome in
            let year = truth.lastYear - 1
            var problems = searchCount(truth.count(year: year), outcome, saysCount: false)
            let inYear = truth.items.filter {
                $0.captureDate.map { Calendar.current.component(.year, from: $0) } == year
            }
            if let top = inYear.max(by: { $0.byteSize < $1.byteSize }), !mentionsName(top, in: outcome.answer) {
                problems.append("the answer never names \(top.name)")
            }
            return problems
        },
        Question(text: "videos bigger than 500 MB") { truth, outcome in
            searchCount(truth.count(minimumMB: 500), outcome)
        },
        Question(text: "how much space do my videos take up") { truth, outcome in
            guard outcome.called([search, "estimate_savings"]) else { return ["no search or estimate was made"] }
            // The total, as the app writes it ("2.9 GB"), without its unit: the model may say GB or gigabytes.
            let figure = ByteFormat.string(truth.totalBytes).split(separator: " ").first.map(String.init) ?? ""
            return !figure.isEmpty && outcome.answer.contains(figure)
                ? [] : ["the answer never says \(figure) (the fixture's total)"]
        },
        Question(text: "can you convert my biggest videos") { truth, outcome in
            // Whatever the model decides, nothing is queued without a tap.
            outcome.jobsAfter == 0 ? [] : ["\(outcome.jobsAfter) videos were queued without a confirmation"]
        },
        Question(text: "why was my last video kept as is") { truth, outcome in
            var problems = outcome.called(["explain_outcome"]) ? [] : ["explain_outcome was never called"]
            let admitsNone = ["no ", "haven't", "nothing", "none", "yet", "not "].contains {
                outcome.answer.localizedCaseInsensitiveContains($0)
            }
            if !admitsNone { problems.append("the answer invents a result; nothing has been converted") }
            return problems
        },
    ]

    // MARK: Run

    private static func ask(_ question: String, rig: Rig) async -> Outcome {
        let client = SystemLanguageModelClient()
        let model = rig.model
        let chat = AssistantChat(
            client: client, availability: AssistantAvailability(client: client, observesActivation: false),
            store: ChatStore(directory: nil), tools: { ConvertAssistantToolProvider(model: model).assistantTools() })
        chat.send(question)
        // A confirmation card halts the answer until it is tapped: cancel it (the rule under test is that nothing
        // runs without a Confirm), after which the model answers once more.
        var sawConfirmation = false
        let deadline = ContinuousClock.now + .seconds(150)
        while ContinuousClock.now < deadline {
            if let card = chat.items.last(where: {
                if case .confirmation(let c) = $0.content { c.state == .pending } else { false }
            }) {
                sawConfirmation = true
                chat.cancel(card.id)
            }
            if !chat.isGenerating && !chat.hasPendingConfirmation && chat.items.count > 1 { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await chat.waitUntilIdle()
        let answer =
            chat.items.reversed().compactMap { item -> String? in
                if case .assistant(let text) = item.content { text } else { nil }
            }.first ?? ""
        let calls = chat.items.compactMap { item -> ChatToolCall? in
            if case .toolCall(let call) = item.content { call } else { nil }
        }
        return Outcome(
            answer: answer, calls: calls, sawConfirmation: sawConfirmation, jobsAfter: model.queuedJobs.count)
    }

    @Test(
        .timeLimit(.minutes(60)),
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_REAL_AI"] == "1" && SystemLanguageModelClient().isAvailable,
            "Set RUN_REAL_AI=1 on a machine with Apple Intelligence"))
    func everydayQuestionsGetTheRightToolAndTheFixturesFacts() async throws {
        var options = ClipOptions()
        options.includeAudio = false
        let clip = try await FixtureFactory.makeClip(options)
        defer { try? FileManager.default.removeItem(at: clip) }
        let thisYear = Calendar.current.component(.year, from: .now)

        var passed = 0
        var total = 0
        for library in Library.allCases {
            for question in Self.questions {
                // A fresh library per question: an action must not leave the next question a different truth.
                let rig = try await Self.makeRig(library, clip: clip)
                defer { rig.cleanUp() }
                let truth = Truth(
                    items: rig.items, photos: rig.model.photos.items, files: rig.model.library.items,
                    lastYear: thisYear - 1)
                let outcome = await Self.ask(question.text, rig: rig)
                let problems = question.judge(truth, outcome)
                total += 1
                if problems.isEmpty { passed += 1 }
                let tools = outcome.calls.map { "\($0.toolName)(\($0.count.map(String.init) ?? "-"))" }
                print(
                    "REAL-AI-CASE [\(library.rawValue)] \"\(question.text)\" \(problems.isEmpty ? "PASS" : "FAIL") "
                        + "tools=\(tools) card=\(outcome.sawConfirmation) answer=\(outcome.answer.prefix(220))"
                        .replacingOccurrences(of: "\n", with: " "))
                for problem in problems {
                    Issue.record(
                        "[\(library.rawValue)] \"\(question.text)\": \(problem). Answer: \(outcome.answer.prefix(220))")
                }
            }
        }
        print(
            "REAL-AI-EVAL pass rate: \(passed)/\(total) (\(Int((Double(passed) / Double(max(total, 1)) * 100).rounded()))%)"
        )
    }

    /// The fixture itself, without the model: the library loads with the big local file and the truth is what the
    /// questions are judged against. Runs always, so a broken fixture shows up before a slow model run.
    @Test func theFixtureLibraryLoadsAsDescribed() async throws {
        var options = ClipOptions()
        options.includeAudio = false
        let clip = try await FixtureFactory.makeClip(options)
        defer { try? FileManager.default.removeItem(at: clip) }
        for library in Library.allCases {
            let rig = try await Self.makeRig(library, clip: clip)
            defer { rig.cleanUp() }
            #expect(rig.model.photos.items.count == (library.hasPhotos ? 6 : 0), "\(library.rawValue) photos")
            #expect(rig.model.library.items.count == (library.hasFiles ? 3 : 0), "\(library.rawValue) files")
            if library.hasFiles {
                #expect(rig.model.library.items.contains { $0.byteSize >= 150_000_000 })
            }
        }
    }
}
