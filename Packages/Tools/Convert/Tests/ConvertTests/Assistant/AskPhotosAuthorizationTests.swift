import AppCore
import AppServices
import CoreGraphics
import Foundation
import PhotosLibrary
import Testing

@testable import Assistant
@testable import Convert

/// The Photos library and Ask for each answer the person can have given to the Photos prompt: not asked yet, limited,
/// denied and full access. A library that can't be read is empty to Ask, never an error and never someone else's data.
@MainActor
@Suite(.serialized) struct AskPhotosAuthorizationTests {
    private static let created = Date(timeIntervalSince1970: 1_750_000_000)

    private static func asset(_ id: String, name: String, megabytes: Int64) -> PhotoAsset {
        PhotoAsset(
            id: id, creationDate: created, location: nil, pixelSize: CGSize(width: 3840, height: 2160),
            duration: 10, originalFileName: name, originalByteSize: megabytes * 1_000_000, modificationDate: created)
    }

    /// What the library holds, and what the person lets the app see under limited access (two of the three).
    private static let all = [
        asset("A/L0/001", name: "Beach.MOV", megabytes: 900),
        asset("B/L0/001", name: "Party.MOV", megabytes: 800),
        asset("C/L0/001", name: "Hike.MOV", megabytes: 700),
    ]

    private struct Rig {
        let model: ConvertModel
        let chat: AssistantChat
        let client: ScriptedChatClient
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func rig(authorization: PhotoAuthorization, assets: [PhotoAsset], tool: String) async throws -> Rig {
        let directory = URL.temporaryDirectory.appending(
            path: "ask-auth-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = UserDefaults(suiteName: "AskPhotosAuthorizationTests-\(UUID().uuidString)")!
        let store = FakePhotoStore(assets: assets, authorization: authorization)
        let services = AppServices(directory: directory, defaults: suite, photoStore: store)
        let model = ConvertModel(services: services)
        await model.photos.start()
        await model.photos.waitUntilIdle()
        let client = ScriptedChatClient { _ in [.tool(tool), .text("Done.")] }
        let chat = AssistantChat(
            client: client, availability: AssistantAvailability(client: client, observesActivation: false),
            store: ChatStore(directory: nil), tools: { ConvertAssistantToolProvider(model: model).assistantTools() })
        return Rig(model: model, chat: chat, client: client, directory: directory)
    }

    private func ask(_ rig: Rig) async throws -> String {
        rig.chat.send("go")
        await rig.chat.waitUntilIdle()
        return try #require(rig.client.toolResults.first)
    }

    @Test func fullAccessLetsTheLibraryLoadAndAskSeeEveryVideo() async throws {
        let rig = try await rig(authorization: .authorized, assets: Self.all, tool: "search_library")
        defer { rig.cleanUp() }
        #expect(rig.model.photos.authorization == .authorized)
        #expect(rig.model.photos.items.count == 3)
        let result = try await ask(rig)
        #expect(result.hasPrefix("Found 3 videos in total, 2.4 GB combined"))
        #expect(result.contains("Beach.MOV") && result.contains("Hike.MOV"))
    }

    @Test func limitedAccessLoadsWhatThePersonPickedAndAskSeesOnlyThat() async throws {
        let rig = try await rig(authorization: .limited, assets: Array(Self.all.prefix(2)), tool: "search_library")
        defer { rig.cleanUp() }
        #expect(rig.model.photos.authorization == .limited)
        #expect(rig.model.photos.items.count == 2)
        let result = try await ask(rig)
        #expect(result.hasPrefix("Found 2 videos in total, 1.7 GB combined"))
        #expect(!result.contains("Hike.MOV"))
    }

    @Test(arguments: [PhotoAuthorization.denied, .notDetermined])
    func withoutAccessTheLibraryIsEmptyAndAskSaysSoWithoutFailing(state: PhotoAuthorization) async throws {
        let rig = try await rig(authorization: state, assets: Self.all, tool: "search_library")
        defer { rig.cleanUp() }
        #expect(rig.model.photos.authorization == state)
        #expect(rig.model.photos.items.isEmpty)
        let result = try await ask(rig)
        #expect(result.hasPrefix("No videos found. The library is empty"))
        guard case .toolCall(let call) = rig.chat.items[1].content else {
            Issue.record("expected a tool row")
            return
        }
        #expect(call.count == 0 && call.state == .done)
    }

    @Test(arguments: [PhotoAuthorization.denied, .notDetermined])
    func withoutAccessAskNeverOffersToConvertAnything(state: PhotoAuthorization) async throws {
        let rig = try await rig(authorization: state, assets: Self.all, tool: "estimate_savings")
        defer { rig.cleanUp() }
        let result = try await ask(rig)
        #expect(result == "Nothing in the library would free space.")
    }

    @Test func limitedAccessEstimatesOnlyWhatItCanSee() async throws {
        let rig = try await rig(authorization: .limited, assets: Array(Self.all.prefix(1)), tool: "estimate_savings")
        defer { rig.cleanUp() }
        let result = try await ask(rig)
        #expect(result.contains("across 1 videos") || result.contains("across 1 video"))
    }
}
