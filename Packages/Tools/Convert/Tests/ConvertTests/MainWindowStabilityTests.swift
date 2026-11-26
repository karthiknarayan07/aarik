#if os(macOS)
    import AppCore
    import AppKit
    import AppServices
    import AppUI
    import Assistant
    import Foundation
    import PhotosLibrary
    import SwiftUI
    import Testing

    @testable import Convert
    @testable import ConvertUI

    /// The main window keeps its frame while the sidebar selection changes, on every page and with the inspector
    /// shown or hidden. The window is the real one: the same hosting controller setup and root view as the app, with the
    /// real Convert scene, shown at zero opacity.
    @MainActor
    @Suite(.serialized) struct MainWindowStabilityTests {
        private final class Box<Value> {
            var value: Value
            init(_ value: Value) { self.value = value }
        }

        @MainActor private struct Harness {
            let window: NSWindow
            let scene: ConvertMacScene
            let directory: URL
            let visibility: Box<NavigationSplitViewVisibility>

            func tearDown() {
                window.close()
                try? FileManager.default.removeItem(at: directory)
            }
        }

        private static func pump(_ seconds: TimeInterval = 0.25) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }

        private static func makeHarness(askAvailable: Bool = false) throws -> Harness? {
            guard !NSScreen.screens.isEmpty else { return nil }
            _ = NSApplication.shared
            let directory = URL.temporaryDirectory.appending(
                path: "window-stability-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let defaults = UserDefaults(suiteName: "MainWindowStabilityTests-\(UUID().uuidString)")!
            // A scripted model stands in for Apple Intelligence, so the Ask page is in the sidebar when asked for.
            let client = ScriptedChatClient(isAvailable: askAvailable, reason: .notEnabled) { _ in [] }
            let services = AppServices(
                directory: directory, defaults: defaults, photoStore: FakePhotoStore(), assistantClient: client)
            let scene = ConvertMacScene(model: ConvertModel(services: services))
            scene.selection = .overview
            let visibility = Box(NavigationSplitViewVisibility.automatic)
            let hosting = MainWindowLayout.makeHostingController(
                rootView: MacRootView(
                    module: scene,
                    sidebarVisibility: Binding {
                        visibility.value
                    } set: {
                        visibility.value = $0
                    }))
            let window = NSWindow(contentViewController: hosting)
            MainWindowLayout.configure(window)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            pump(0.6)
            return Harness(window: window, scene: scene, directory: directory, visibility: visibility)
        }

        @Test func switchingPagesNeverChangesTheWindowFrame() throws {
            guard let harness = try Self.makeHarness() else { return }
            defer { harness.tearDown() }
            let initial = harness.window.frame
            var changes: [String] = []
            for round in 0..<2 {
                for page in harness.scene.selectableDestinations {
                    harness.scene.selection = page
                    Self.pump()
                    if harness.window.frame != initial {
                        changes.append("\(page) (round \(round)): \(harness.window.frame) vs \(initial)")
                    }
                }
            }
            #expect(changes.isEmpty, "The window frame changed on navigation: \(changes)")
        }

        @Test func theAskPageKeepsTheWindowFrameToo() throws {
            guard let harness = try Self.makeHarness(askAvailable: true) else { return }
            defer { harness.tearDown() }
            #expect(harness.scene.selectableDestinations.last == .ask)
            let initial = harness.window.frame
            for page in [VideoPage.localFiles, .ask, .queue, .ask, .overview] {
                harness.scene.selection = page
                Self.pump()
                #expect(harness.window.frame == initial, "\(page)")
            }
            harness.scene.selection = .ask
            for _ in 0..<2 {
                harness.scene.isInspectorPresented.toggle()
                Self.pump()
                #expect(harness.window.frame == initial)
            }
        }

        @Test func togglingTheInspectorNeverChangesTheWindowFrame() throws {
            guard let harness = try Self.makeHarness() else { return }
            defer { harness.tearDown() }
            harness.scene.selection = .localFiles
            Self.pump()
            let initial = harness.window.frame
            for _ in 0..<2 {
                harness.scene.isInspectorPresented.toggle()
                Self.pump()
                #expect(harness.window.frame == initial)
            }
        }

        @Test func windowLayoutNeverLetsSwiftUIDriveTheSize() {
            #expect(MainWindowLayout.sizingOptions.isEmpty)
            let hosting = MainWindowLayout.makeHostingController(rootView: EmptyView())
            #expect(hosting.sizingOptions.isEmpty)
            #expect(hosting.sceneBridgingOptions == .all)
            _ = NSApplication.shared
            let window = NSWindow(contentViewController: hosting)
            MainWindowLayout.configure(window)
            #expect(window.contentMinSize == MainWindowLayout.minimumContentSize)
            #expect(window.styleMask.contains(.resizable))
        }
    }
#endif
