#if os(macOS)
    import AppCore
    import AppKit
    import AppServices
    import AppUI
    import Assistant
    import Foundation
    import LocalLibrary
    import PhotosLibrary
    import SwiftUI
    import Testing

    @testable import AppUI
    @testable import Convert
    @testable import ConvertUI

    /// Renders the Mac Ask page, in the real main window, to PNGs for design review. The model is a scripted fake with
    /// made-up tools, so nothing here touches Apple Intelligence, the library or the queue. Skipped unless
    /// `APP_ASK_SHOTS` names the folder to write to:
    ///
    ///     APP_ASK_SHOTS=/path/to/folder swift test --filter AskScreenshotTests
    @MainActor
    @Suite(.serialized) struct AskScreenshotTests {
        private struct DemoTool: AssistantTool {
            let name: String
            let requiresConfirmation: Bool
            let output: AssistantToolOutput
            var summary: String { "Demo." }

            func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
                AssistantConfirmation(
                    title: "Convert 14 Videos", message: "Save about 6.2 GB? The originals stay where they are.")
            }

            func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput { output }
        }

        private struct DemoProvider: AssistantToolProvider {
            func assistantTools() -> [any AssistantTool] {
                [
                    DemoTool(
                        name: "demo_search", requiresConfirmation: false,
                        output: AssistantToolOutput(
                            text: "42 videos found.", title: "Searched Library", count: 42,
                            lines: ["Beach Day · 1.8 GB", "Birthday Dinner · 1.2 GB", "Hike Summit · 1.1 GB"])),
                    DemoTool(
                        name: "demo_estimate", requiresConfirmation: false,
                        output: AssistantToolOutput(
                            text: "About 6.2 GB across 14 videos.", title: "Estimated Savings", count: 14)),
                    DemoTool(
                        name: "demo_convert", requiresConfirmation: true,
                        output: AssistantToolOutput(text: "14 videos are in the queue.", title: "Queued Videos")),
                ]
            }
        }

        private static func client(chunk: Int = 400, delay: Duration? = nil) -> ScriptedChatClient {
            ScriptedChatClient(chunk: chunk, delay: delay) { prompt in
                let text = prompt.lowercased()
                if text.contains("biggest") {
                    return [
                        .tool("demo_search"),
                        .text(
                            "Your biggest videos are 4K clips from last summer. The largest is Beach Day at 1.8 GB, "
                                + "then Birthday Dinner at 1.2 GB."),
                    ]
                }
                if text.contains("save") {
                    return [
                        .tool("demo_estimate"),
                        .text("Converting your biggest 4K videos could free about 6.2 GB. Want me to queue them?"),
                    ]
                }
                if text.contains("convert") { return [.tool("demo_convert"), .text("Done. 14 videos are queued.")] }
                return [.text("Beach Day is large because it is 4K at 60 fps, about 100 Mbit/s.")]
            }
        }

        @MainActor private struct Session {
            let window: NSWindow
            let model: ConvertModel
            let scene: ConvertMacScene
            let directory: URL
            var chat: AssistantChat { model.services.assistantChat }
        }

        private static func session(client: ScriptedChatClient, dark: Bool) throws -> Session? {
            guard !NSScreen.screens.isEmpty else { return nil }
            _ = NSApplication.shared
            let directory = URL.temporaryDirectory.appending(
                path: "ask-shots-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let services = AppServices(
                directory: directory, defaults: UserDefaults(suiteName: "AskShots-\(UUID().uuidString)")!,
                photoStore: FakePhotoStore(), assistantClient: client)
            services.registerAssistantTools(DemoProvider())
            let model = ConvertModel(services: services)
            let scene = ConvertMacScene(model: model)
            scene.selection = .ask
            let hosting = MainWindowLayout.makeHostingController(
                rootView: MacRootView(module: scene, sidebarVisibility: .constant(.automatic)))
            let window = NSWindow(contentViewController: hosting)
            MainWindowLayout.configure(window)
            window.setContentSize(NSSize(width: 1180, height: 740))
            window.title = AppInfo.displayName
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            pump(0.8)
            return Session(window: window, model: model, scene: scene, directory: directory)
        }

        private static func pump(_ seconds: TimeInterval = 0.4) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }

        private static func snapshot(_ session: Session, name: String, dark: Bool, folder: URL) throws {
            pump(0.6)
            guard let view = session.window.contentView?.superview ?? session.window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        /// The conversation itself with `ImageRenderer`: a window snapshot can't capture a scroll view's rows.
        private static func renderTranscript(_ chat: AssistantChat, name: String, dark: Bool, folder: URL) throws {
            let content = VStack(alignment: .leading, spacing: 14) {
                ForEach(chat.items) { item in
                    ChatItemView(
                        item: item, chat: chat, isStreaming: chat.isGenerating && item.id == chat.items.last?.id,
                        isLast: item.id == chat.items.last?.id)
                }
            }
            .padding(24)
            .frame(width: 760, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try png.write(to: folder.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
        }

        private static func finish(_ session: Session) {
            session.window.close()
            try? FileManager.default.removeItem(at: session.directory)
        }

        private static func ask(_ chat: AssistantChat, _ prompts: String...) async {
            for prompt in prompts {
                chat.send(prompt)
                await chat.waitUntilIdle()
            }
        }

        private static func folder() throws -> URL? {
            guard let path = ProcessInfo.processInfo.environment["APP_ASK_SHOTS"] else { return nil }
            let url = URL(filePath: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private static let sampleVideo = LibraryItem(
            id: UUID(), url: URL(filePath: "/Users/example/Movies/Beach Day.mov"), byteSize: 1_800_000_000,
            duration: 150, pixelSize: CGSize(width: 3840, height: 2160), frameRate: 60, captureDate: Date(),
            badges: [.k4], isAvailable: true, inventory: MetadataInventory(items: []))

        @Test func rendersTheAskPage() async throws {
            guard let folder = try Self.folder() else { return }
            for dark in [false, true] {
                // 1. A new chat: the hero and the starting questions.
                var shot = try #require(try Self.session(client: Self.client(), dark: dark))
                try Self.snapshot(shot, name: "1-empty", dark: dark, folder: folder)
                Self.finish(shot)

                // 2. Ask About This…: the video as context, with its own starting questions.
                shot = try #require(try Self.session(client: Self.client(), dark: dark))
                shot.model.askAbout(Self.sampleVideo)
                try Self.snapshot(shot, name: "2-about-video", dark: dark, folder: folder)
                Self.finish(shot)

                // 3. A finished answer with a tool row, and history in the inspector.
                shot = try #require(try Self.session(client: Self.client(), dark: dark))
                await Self.ask(shot.chat, "Find my biggest videos")
                shot.chat.newChat()
                await Self.ask(shot.chat, "How much can I save?")
                shot.chat.newChat()
                await Self.ask(shot.chat, "Find my biggest videos", "How much can I save?")
                try Self.snapshot(shot, name: "3-conversation-and-history", dark: dark, folder: folder)
                try Self.renderTranscript(shot.chat, name: "3-transcript", dark: dark, folder: folder)
                Self.finish(shot)

                // 4. An action waiting for Confirm or Cancel.
                shot = try #require(try Self.session(client: Self.client(), dark: dark))
                shot.chat.send("Convert them")
                while !shot.chat.hasPendingConfirmation { await Task.yield() }
                try Self.snapshot(shot, name: "4-confirmation", dark: dark, folder: folder)
                try Self.renderTranscript(shot.chat, name: "4-transcript-confirmation", dark: dark, folder: folder)
                shot.chat.stop()
                Self.finish(shot)

                // 5. An answer streaming in.
                shot = try #require(
                    try Self.session(client: Self.client(chunk: 2, delay: .milliseconds(120)), dark: dark))
                shot.chat.send("Why is it big?")
                Self.pump(1.0)
                try Self.snapshot(shot, name: "5-streaming", dark: dark, folder: folder)
                try Self.renderTranscript(shot.chat, name: "5-transcript-streaming", dark: dark, folder: folder)
                shot.chat.stop()
                Self.finish(shot)

                // 6. Apple Intelligence went away while the page was open.
                let off = ScriptedChatClient(isAvailable: false, reason: .notEnabled) { _ in [] }
                shot = try #require(try Self.session(client: off, dark: dark))
                try Self.snapshot(shot, name: "6-unavailable", dark: dark, folder: folder)
                Self.finish(shot)
            }
        }
    }
#endif
