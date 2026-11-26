import AppCore
import AppServices
import AppUI
import Foundation
import LocalLibrary
import PhotosLibrary
import Testing

@testable import Assistant
@testable import Convert

@MainActor
private func makeModel(askAvailable: Bool) throws -> (ConvertModel, URL) {
    let directory = URL.temporaryDirectory.appending(path: "ask-page-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let client = ScriptedChatClient(isAvailable: askAvailable, reason: askAvailable ? nil : .notEnabled) { _ in
        [.text("Fine.")]
    }
    let services = AppServices(
        directory: directory, defaults: UserDefaults(suiteName: "AskPageTests-\(UUID().uuidString)")!,
        photoStore: FakePhotoStore(), assistantClient: client)
    return (ConvertModel(services: services), directory)
}

private func video(name: String = "Beach Day.mov") -> LibraryItem {
    LibraryItem(
        id: UUID(), url: URL(filePath: "/Users/example/Private Folder/\(name)"), byteSize: 1_800_000_000,
        duration: 42, pixelSize: CGSize(width: 3840, height: 2160), frameRate: 60, captureDate: nil, badges: [.k4],
        isAvailable: true, inventory: MetadataInventory(items: []))
}

@Suite struct AskSidebarTests {
    private func state(showsAsk: Bool) -> VideoSidebarState {
        VideoSidebarState(
            photosCount: nil, localCount: 0, badgeCounts: [:], activity: .init(jobs: []), showsAsk: showsAsk)
    }

    @Test func askIsListedOnlyWhileTheAssistantIsAvailable() {
        let without = VideoSidebar.sections(state(showsAsk: false))
        #expect(without.flatMap(\.items).allSatisfy { $0.destination != .ask })

        let with = VideoSidebar.sections(state(showsAsk: true))
        #expect(with.last?.title == "Assistant")
        #expect(with.last?.items.map(\.title) == ["Ask"])
        #expect(with.last?.items.map(\.systemImage) == ["sparkles"])
    }

    @Test func askComesAfterEveryOtherPageSoTheShortcutsDontMove() {
        let titles = VideoSidebar.sections(state(showsAsk: true)).flatMap(\.items).map(\.title)
        #expect(titles.last == "Ask")
        #expect(VideoPage.ask.title == "Ask")
        #expect(!VideoPage.ask.showsLibrary)
        #expect(IOSPage(.ask) == nil)
    }
}

@MainActor
@Suite struct AskModelTests {
    @Test func theGoMenuGainsAskAsTheEighthPageOnlyWhenAvailable() throws {
        let (on, onDirectory) = try makeModel(askAvailable: true)
        let (off, offDirectory) = try makeModel(askAvailable: false)
        defer { for url in [onDirectory, offDirectory] { try? FileManager.default.removeItem(at: url) } }
        #expect(on.goDestinations() == ConvertModel.goDestinations + [.ask])
        #expect(off.goDestinations() == ConvertModel.goDestinations)
        #expect(ConvertModel.goDestinations.count == 7)
    }

    @Test func newChatIsEnabledOnlyOnTheAskPage() throws {
        let (model, directory) = try makeModel(askAvailable: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.selection = .queue
        #expect(!model.commandContext.canStartNewChat)
        model.selection = .ask
        #expect(model.commandContext.canStartNewChat)
        #expect(AppCommands.command(.newChat, in: model.commandContext).isEnabled)
    }

    @Test func newChatIsOffWhenTheAssistantIsUnavailable() throws {
        let (model, directory) = try makeModel(askAvailable: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.selection = .ask
        #expect(!model.commandContext.canStartNewChat)
    }

    @Test func newChatCommandEmptiesTheChatAndShowsAsk() async throws {
        let (model, directory) = try makeModel(askAvailable: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.host.showMainWindow = {}
        let chat = model.services.assistantChat
        chat.send("Hello")
        await chat.waitUntilIdle()
        #expect(!chat.items.isEmpty)
        model.selection = .queue

        model.perform(.newChat)
        #expect(chat.items.isEmpty)
        #expect(chat.currentID == nil)
        #expect(model.selection == .ask)
    }

    @Test func askAboutThisOpensAFreshChatWithTheVideoAsContext() async throws {
        let (model, directory) = try makeModel(askAvailable: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = model.services.assistantChat
        chat.send("Earlier question")
        await chat.waitUntilIdle()
        model.selection = .localFiles

        model.askAbout(video())
        #expect(model.selection == .ask)
        #expect(chat.items.isEmpty)
        #expect(chat.context?.title == "Beach Day.mov")
    }

    @Test func askAboutThisDoesNothingWhenTheAssistantIsUnavailable() throws {
        let (model, directory) = try makeModel(askAvailable: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.selection = .localFiles
        model.askAbout(video())
        #expect(model.selection == .localFiles)
        #expect(model.services.assistantChat.context == nil)
    }

    @Test func theContextCarriesTheFactsButNeverTheFolder() {
        let context = ChatContext(video: video())
        #expect(context.title == "Beach Day.mov")
        #expect(context.details.contains("3840×2160"))
        #expect(context.details.contains("60 fps"))
        #expect(context.details.contains("42 seconds"))
        #expect(context.details.contains("a local file"))
        #expect(!context.details.contains("Private Folder"))
        #expect(!context.instructions.contains("/Users"))
    }
}
