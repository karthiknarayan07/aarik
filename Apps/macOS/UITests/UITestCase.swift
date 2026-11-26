import XCTest

/// Shared setup for the Mac UI tests: the real app, launched with the Debug-only arguments of `UITestHooks` (a support
/// folder of its own, a generated Local Files library and queue history, a pinned clock, no Photos access, a scripted
/// assistant), and navigation by accessibility identifier.
@MainActor
class UITestCase: XCTestCase {
    /// The window's content size: the app's own default, or the smallest the window allows.
    enum WindowSize: String, CaseIterable {
        case standard = "1280x820"
        case minimum = "900x600"
    }

    var app = XCUIApplication()
    /// Where this test's launch keeps its queue, library and stats (`-uiTesting`).
    private(set) var root = URL(filePath: NSTemporaryDirectory())

    override func setUp() async throws {
        // A failed assertion in an async test with this off was seen to hang the runner, not stop the test; helpers return
        // early after a failed wait instead.
        continueAfterFailure = true
        root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: root)
    }

    /// Launches the app and waits for its window and the library to be read. `assistant` false is a Mac without Apple
    /// Intelligence; true lists Ask (scripted) while the Overview's picks still fall back to plain rows.
    func launch(
        size: WindowSize = .standard, assistant: Bool = true, library: Bool = true, extraArguments: [String] = []
    ) async throws {
        var arguments = [
            "-uiTesting", root.path, "-uiTestingWindowSize", size.rawValue,
            "-uiTestingNow", UITestFixtures.now.formatted(.iso8601),
            "-uiTestingAssistant", "unavailable",
            "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        if assistant { arguments.append("-AssistantDemo") }
        if library {
            try await arguments += ["-uiTestingFiles", UITestFixtures.library().path]
            try UITestFixtures.writeHistory(into: root)
        }
        app.launchArguments = arguments + extraArguments
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 30), "The app didn't show its window")
    }

    var window: XCUIElement { app.windows.firstMatch }

    // MARK: Lookups

    /// The element with this accessibility identifier, of any type.
    func element(_ identifier: String) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The sidebar row of a page ("Home", "Local Files", "Queue", ...).
    func sidebarRow(_ title: String) -> XCUIElement { element("sidebar.\(title)") }
}
