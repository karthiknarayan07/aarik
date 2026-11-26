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
    private let tool = VideoSidebar.sections(
        VideoSidebarState(photosCount: nil, localCount: 0, badgeCounts: [:], activity: .init(jobs: [])))

    @Test func askIsTheShellsAndListedOnlyWhileTheAssistantIsAvailable() {
        #expect(tool.flatMap(\.items).allSatisfy { $0.destination != .ask })
        #expect(MacSidebarModel(showsAsk: true, tool: tool).selectablePages.contains(.ask))
        #expect(!MacSidebarModel(showsAsk: false, tool: tool).selectablePages.contains(.ask))
    }

    @Test func aToolsPagesAreListedOnlyInsideItsGroup() {
        let state = VideoSidebarState(
            photosCount: 3, localCount: 2, badgeCounts: [.k4: 1], activity: .init(jobs: []))
        let sections = VideoSidebar.sections(state)
        // The tool's group holds its own pages and none of the app's.
        let owned = sections.flatMap(\.items).compactMap(\.destination)
        #expect(!owned.contains(.overview) && !owned.contains(.ask))
        let sidebar = MacSidebarModel(showsAsk: true, tool: sections)
        #expect(sidebar.toolRows.compactMap(\.tag) == owned)
        // Everything after Home and Ask is a page of the tool, in the tool's order.
        let pages = sidebar.selectablePages
        #expect(Array(pages.prefix(2)) == [.home, .ask])
        #expect(pages.dropFirst(2).compactMap(\.destination) == owned)
        #expect(pages.dropFirst(2).allSatisfy { $0.destination != nil })
    }

    @Test func appLevelPageTitlesNeverNameATool() {
        for page in [VideoPage.overview, .ask] {
            for noun in ["Convert", "Shrink", "Compress"] {
                #expect(!page.title.localizedCaseInsensitiveContains(noun), "\(page.title) names a tool")
            }
        }
    }

    @Test func askSitsRightAfterHome() {
        #expect(MacSidebarModel(showsAsk: true, tool: tool).selectablePages.prefix(2) == [.home, .ask])
        #expect(VideoPage.ask.title == "Ask")
        #expect(!VideoPage.ask.showsLibrary)
        #expect(IOSPage(.ask) == nil)
    }
}

@MainActor
@Suite struct AskModelTests {
    @Test func theGoMenuFollowsTheSidebarAndAskKeepsItsNumberWhetherOrNotItIsListed() throws {
        let (on, onDirectory) = try makeModel(askAvailable: true)
        let (off, offDirectory) = try makeModel(askAvailable: false)
        defer { for url in [onDirectory, offDirectory] { try? FileManager.default.removeItem(at: url) } }
        #expect(
            ConvertModel.goDestinations == [
                .overview, .ask, .photosVideos, .localFiles, .queue, .completed, .keptAsIs, .failed,
            ])
        #expect(on.goEntries().map(\.page) == ConvertModel.goDestinations)
        #expect(on.goEntries().map(\.index) == Array(0..<8))
        #expect(off.goEntries().map(\.page) == ConvertModel.goDestinations.filter { $0 != .ask })
        // Photos stays ⌘3 with or without Ask.
        #expect(off.goEntries().map(\.index) == [0, 2, 3, 4, 5, 6, 7])
        #expect(VideoPage.overview.title == "Home")
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
