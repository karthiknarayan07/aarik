import AppCore
import AppServices
import CoreGraphics
import Foundation
import PhotosLibrary
import Testing

@testable import Assistant
@testable import Convert

/// The Convert tools the Ask tab offers, driven the way the chat drives them: a scripted model calls the tool and
/// the chat runs it (reads at once, actions after a Confirm tap), on a model whose Photos library is a fake store.
@MainActor
@Suite(.serialized) struct ConvertAssistantToolsTests {
    private static let created = Date(timeIntervalSince1970: 1_750_000_000)

    private static func asset(_ id: String, name: String, megabytes: Int64, height: CGFloat = 2160) -> PhotoAsset {
        PhotoAsset(
            id: id, creationDate: created, location: nil, pixelSize: CGSize(width: height * 16 / 9, height: height),
            duration: 10, originalFileName: name, originalByteSize: megabytes * 1_000_000, modificationDate: created)
    }

    private static let library = [
        asset("A/L0/001", name: "Beach 1.MOV", megabytes: 900),
        asset("B/L0/001", name: "Beach 2.MOV", megabytes: 600),
        asset("C/L0/001", name: "Party.MOV", megabytes: 800),
    ]

    @MainActor private struct Rig {
        let model: ConvertModel
        let chat: AssistantChat
        let client: ScriptedChatClient
        let directory: URL

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        /// The card the chat is waiting on.
        var pendingCard: ChatItem? {
            chat.items.last { if case .confirmation = $0.content { true } else { false } }
        }
    }

    private func rig(
        assets: [PhotoAsset], script: @escaping @Sendable (String) -> [ScriptedChatClient.Step]
    ) async throws -> Rig {
        let directory = URL.temporaryDirectory.appending(
            path: "convert-assistant-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = UserDefaults(suiteName: "ConvertAssistantToolsTests-\(UUID().uuidString)")!
        let services = AppServices(directory: directory, defaults: suite, photoStore: FakePhotoStore(assets: assets))
        let model = ConvertModel(services: services)
        await model.photos.start()
        await model.photos.waitUntilIdle()
        let client = ScriptedChatClient(script: script)
        let chat = AssistantChat(
            client: client, availability: AssistantAvailability(client: client, observesActivation: false),
            store: ChatStore(directory: nil), tools: { ConvertAssistantToolProvider(model: model).assistantTools() })
        return Rig(model: model, chat: chat, client: client, directory: directory)
    }

    private func ask(_ rig: Rig, _ text: String = "go") async {
        rig.chat.send(text)
        await rig.chat.waitUntilIdle()
    }

    @Test func theProviderOffersReadsOnTheirOwnAndActionsBehindAConfirmation() async throws {
        let rig = try await rig(assets: []) { _ in [] }
        defer { rig.cleanUp() }
        let tools = ConvertAssistantToolProvider(model: rig.model).assistantTools()
        #expect(
            tools.filter { !$0.requiresConfirmation }.map(\.name)
                == ["search_library", "estimate_savings", "explain_outcome", "list_queue"])
        #expect(
            tools.filter(\.requiresConfirmation).map(\.name)
                == ["convert_videos", "pause_queue", "resume_queue", "replace_originals"])
    }

    // MARK: Search

    @Test func searchFindsByNameAndSummarisesCountAndSize() async throws {
        let rig = try await rig(assets: Self.library) { _ in
            [.tool("search_library", ["name_contains": "beach"]), .text("Found.")]
        }
        defer { rig.cleanUp() }
        await ask(rig)
        let result = try #require(rig.client.toolResults.first)
        #expect(result.hasPrefix("2 videos, 1.5 GB in all."))
        #expect(result.contains("Beach 1.MOV") && !result.contains("Party"))
        guard case .toolCall(let call) = rig.chat.items[1].content else {
            Issue.record("expected a tool row")
            return
        }
        #expect(call.title == "Searched Library" && call.count == 2 && call.state == .done)
    }

    @Test func searchFiltersBySizeAndSaysWhenNothingMatches() async throws {
        let rig = try await rig(assets: Self.library) { _ in
            [.tool("search_library", ["minimum_size_mb": "850"]), .tool("search_library", ["name_contains": "zebra"])]
        }
        defer { rig.cleanUp() }
        await ask(rig)
        #expect(rig.client.toolResults.count == 2)
        #expect(rig.client.toolResults[0].hasPrefix("1 videos"))
        #expect(rig.client.toolResults[1] == "No videos match.")
    }

    // MARK: Savings

    @Test func savingsListsTheGroupsWithIds() async throws {
        let rig = try await rig(assets: Self.library) { _ in [.tool("estimate_savings")] }
        defer { rig.cleanUp() }
        await ask(rig)
        let result = try #require(rig.client.toolResults.first)
        #expect(result.hasPrefix("Converting everything could free about"))
        #expect(result.contains("B1:"))
        guard case .toolCall(let call) = rig.chat.items[1].content else {
            Issue.record("expected a tool row")
            return
        }
        #expect(call.title == "Estimated Savings" && call.count == 1)
    }

    @Test func savingsOnAnEmptyLibraryFreesNothing() async throws {
        let rig = try await rig(assets: []) { _ in [.tool("estimate_savings")] }
        defer { rig.cleanUp() }
        await ask(rig)
        #expect(rig.client.toolResults == ["Nothing in the library would free space."])
    }

    // MARK: Outcome

    @Test func outcomeWithNothingFinishedTellsTheModelSo() async throws {
        let rig = try await rig(assets: Self.library) { _ in [.tool("explain_outcome")] }
        defer { rig.cleanUp() }
        await ask(rig)
        #expect(rig.client.toolResults == ["No finished conversion matches."])
        guard case .toolCall(let call) = rig.chat.items[1].content else {
            Issue.record("expected a tool row")
            return
        }
        #expect(call.state == .failed)
    }

    @Test func outcomeExplainsAFailedJobFromItsFactsOnly() async throws {
        let rig = try await rig(assets: []) { _ in [.tool("explain_outcome", ["video_name": "birthday"])] }
        defer { rig.cleanUp() }
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal)
        let failed = Job(
            toolID: ConvertTool.toolID, source: URL(filePath: "/Users/jane/Birthday.mov"), sourceBookmark: Data(),
            settings: try JSONEncoder().encode(settings),
            state: .failed(reason: "Not enough space", code: .notEnoughSpace))
        await rig.model.services.start()
        await rig.model.services.queue.enqueue([failed])
        var waits = 0
        while rig.model.jobs.isEmpty, waits < 10_000 {
            await Task.yield()
            waits += 1
        }
        await ask(rig)
        let result = try #require(rig.client.toolResults.first)
        #expect(result != "No finished conversion matches.")
        #expect(!result.contains("/Users") && !result.contains("jane"))
    }

    // MARK: Queue

    @Test func listQueueSaysEmptyAndPaused() async throws {
        let rig = try await rig(assets: []) { _ in [.tool("list_queue")] }
        defer { rig.cleanUp() }
        rig.model.isQueuePaused = false
        await ask(rig)
        #expect(rig.client.toolResults == ["The queue is empty."])

        rig.model.isQueuePaused = true
        await ask(rig, "again")
        #expect(rig.client.toolResults.last == "The queue is paused. The queue is empty.")
    }

    @Test func convertAsksFirstAndQueuesOnlyAfterConfirm() async throws {
        let rig = try await rig(assets: Self.library) { _ in
            [.tool("estimate_savings"), .tool("convert_videos", ["group": "B1"]), .text("Queued.")]
        }
        defer { rig.cleanUp() }
        rig.chat.send("convert")
        while !rig.chat.hasPendingConfirmation { await Task.yield() }
        let cardItem = try #require(rig.pendingCard)
        guard case .confirmation(let pending) = cardItem.content else { return }
        #expect(pending.card.title == "Convert 3 Videos")
        #expect(pending.card.confirmLabel == "Convert")
        #expect(rig.model.queuedJobs.isEmpty)

        rig.chat.confirm(cardItem.id)
        await rig.chat.waitUntilIdle()
        let result = try #require(rig.client.toolResults.last)
        #expect(result.hasPrefix("Started adding 3 videos to the queue."))
    }

    @Test func convertDeclinedChangesNothing() async throws {
        let rig = try await rig(assets: Self.library) { _ in [.tool("convert_videos"), .text("Okay.")] }
        defer { rig.cleanUp() }
        rig.chat.send("convert")
        while !rig.chat.hasPendingConfirmation { await Task.yield() }
        rig.chat.cancel(try #require(rig.pendingCard).id)
        await rig.chat.waitUntilIdle()
        #expect(rig.client.toolResults == ["The person chose not to go ahead. Nothing was changed."])
        #expect(rig.model.queuedJobs.isEmpty)
    }

    @Test func convertWithAnUnknownGroupIsRefusedBeforeAsking() async throws {
        let rig = try await rig(assets: Self.library) { _ in [.tool("convert_videos", ["group": "B9"])] }
        defer { rig.cleanUp() }
        await ask(rig)
        #expect(!rig.chat.hasPendingConfirmation)
        #expect(rig.client.toolResults == ["There is no group B9. Use a group id from the savings estimate."])
    }

    @Test func pauseAndResumeAskOnlyWhenTheyChangeSomething() async throws {
        let rig = try await rig(assets: []) { _ in [.tool("resume_queue"), .tool("pause_queue"), .text("Done.")] }
        defer { rig.cleanUp() }
        rig.model.isQueuePaused = false
        rig.chat.send("go")
        // Resume while running is refused without a card; pause asks first.
        while !rig.chat.hasPendingConfirmation { await Task.yield() }
        let cardItem = try #require(rig.pendingCard)
        guard case .confirmation(let pending) = cardItem.content else { return }
        #expect(pending.card.title == "Pause the Queue")
        #expect(!rig.model.isQueuePaused)
        rig.chat.confirm(cardItem.id)
        await rig.chat.waitUntilIdle()
        #expect(rig.client.toolResults == ["The queue isn't paused.", "The queue is paused."])
        #expect(rig.model.isQueuePaused)
    }

    @Test func replaceOriginalsNeedsSomethingWaitingToMove() async throws {
        let rig = try await rig(assets: []) { _ in [.tool("replace_originals")] }
        defer { rig.cleanUp() }
        await ask(rig)
        #expect(!rig.chat.hasPendingConfirmation)
        #expect(rig.client.toolResults == ["No originals are waiting to be moved."])
    }
}
