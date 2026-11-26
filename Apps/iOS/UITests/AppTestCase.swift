import XCTest

/// Shared setup for the iOS UI tests: a fresh support folder per launch (so a test never touches another test's queue
/// or library), the queue's auto-start and speed pinned by launch arguments, and navigation that works in the
/// compact stack (iPhone, folded Duo) and the split view (iPad, unfolded Duo).
///
/// The Simulator's Photos library holds the generated fixtures `scripts/ios-ui-tests.sh` adds with `simctl addmedia`
/// (never anyone's own media); that script also grants Photos access and puts a file in Files.
@MainActor
class AppTestCase: XCTestCase {
    static let photosFixture = "clip-a.mov"
    static let secondPhotosFixture = "clip-b.mov"
    static let filesFixture = "files-fixture.mov"

    var app = XCUIApplication()
    /// Where this test's app launches keep their queue, library and Staging (`-uiTesting`).
    private(set) var supportDirectory = ""
    /// Where a test stages a share or intent hand-off (`-uiTestingHandoff`).
    private(set) var handoffDirectory = ""

    override func setUp() async throws {
        continueAfterFailure = false
        let base = NSTemporaryDirectory() + "ui-\(UUID().uuidString)"
        supportDirectory = base + "/support"
        handoffDirectory = base + "/handoff"
        try FileManager.default.createDirectory(atPath: handoffDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: (supportDirectory as NSString).deletingLastPathComponent)
    }

    /// Points the next launch at an empty queue and library (for tests that launch the app more than once and need
    /// each launch to start clean).
    func resetSupportDirectory() {
        try? FileManager.default.removeItem(atPath: supportDirectory)
    }

    /// Launches the app. `autoStart` false keeps the queue paused so a queued job stays queued; `contentSize` is a
    /// `UICTContentSizeCategory…` name.
    func launch(
        autoStart: Bool = true, contentSize: String? = nil, pinSpeed: Bool = true, extraArguments: [String] = [],
        terminateFirst: Bool = false
    ) {
        if terminateFirst { app.terminate() }
        var arguments = [
            "-uiTesting", supportDirectory, "-uiTestingHandoff", handoffDirectory,
            "-queue.autoStart", autoStart ? "<true/>" : "<false/>",
        ]
        if pinSpeed { arguments += ["-performance.speed", "balanced"] }
        if let contentSize { arguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchArguments = arguments + extraArguments
        app.launch()
        XCTAssertTrue(root.waitForExistence(timeout: 30), "The app didn't show its root view")
    }

    var root: XCUIElement { app.descendants(matching: .any)["root"].firstMatch }

    // MARK: Navigation

    /// Brings the sidebar into view: in the compact stack it is the root, so the detail's Back button leads to it; in a
    /// regular width with the sidebar collapsed (iPad portrait) the toolbar's Show Sidebar button reveals it.
    func revealSidebar() {
        let back = app.buttons["BackButton"].firstMatch
        if back.exists, back.isHittable {
            back.tap()
            return
        }
        let show = app.buttons["Show Sidebar"].firstMatch
        if show.exists, show.isHittable { show.tap() }
    }

    /// Selects a sidebar page by its title ("Videos", "Local Files", "Queue", "Completed"...).
    func open(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.buttons[page].firstMatch
        if !item.waitForExistence(timeout: 2) || !item.isHittable { revealSidebar() }
        if !item.waitForExistence(timeout: 15) { dump("missing sidebar item \(page)") }
        XCTAssertTrue(item.exists, "No sidebar item \(page)", file: file, line: line)
        item.tap()
    }

    /// Opens Settings from the sidebar's toolbar.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons["Settings…"].firstMatch
        if !settings.waitForExistence(timeout: 2) || !settings.isHittable { revealSidebar() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "No Settings button", file: file, line: line)
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings didn't open", file: file,
            line: line)
    }

    // MARK: Lookups

    func element(labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func tile(named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    // MARK: Flows

    /// Opens Photos videos, selects the named fixture and adds it to the queue.
    func queuePhotosFixture(
        _ name: String = AppTestCase.photosFixture, file: StaticString = #filePath, line: UInt = #line
    ) {
        open("Videos", file: file, line: line)
        let tile = tile(named: name)
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name) isn't in the Photos grid", file: file, line: line)
        scrollToHittable(tile)
        tile.tap()
        let add = app.buttons["Add to Queue"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), file: file, line: line)
        if !add.isEnabled {
            dump("Add to Queue disabled after selecting")
        }
        XCTAssertTrue(add.isEnabled, "Add to Queue stayed disabled after selecting a video", file: file, line: line)
        add.tap()
        confirmLossIfAsked()
    }

    /// Swipes the grid up until `element`'s centre is comfortably on screen (at large Dynamic Type sizes the tiles are
    /// tall, and a tile can report itself hittable while its centre sits under the search bar).
    func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 8) {
        let window = app.windows.firstMatch.frame
        var swipes = 0
        while (!element.isHittable || element.frame.midY > window.height * 0.85), swipes < maxSwipes {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    /// A conversion that would lose metadata asks first; the fixtures carry camera metadata so it shouldn't, but a
    /// sheet must never leave a test stuck.
    func confirmLossIfAsked() {
        let convert = app.buttons["Convert"].firstMatch
        if app.sheets.firstMatch.waitForExistence(timeout: 1), convert.exists { convert.tap() }
    }

    /// Waits until a completed row for the fixture shows on Completed.
    func waitForCompleted(
        _ name: String = "clip-a", timeout: TimeInterval = 240, file: StaticString = #filePath, line: UInt = #line
    ) {
        open("Completed", file: file, line: line)
        let appeared = element(labelContaining: name).waitForExistence(timeout: timeout)
        if !appeared { dump("\(name) never reached Completed") }
        XCTAssertTrue(
            appeared,
            "\(name) never reached Completed", file: file, line: line)
    }

    /// Prints the labelled elements on screen (for working out why a query missed).
    func dump(_ tag: String) {
        let lines = app.debugDescription.split(separator: "\n").filter {
            $0.contains("label:") && !$0.contains("Other,")
        }
        print("DUMP \(tag)\n" + lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
    }

    /// The queue's progress text ("Converting… · 70%") of the running job; it only exists while a job is converting.
    var runningProgress: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS '%'")).firstMatch
    }

    var fixtureDirectory: String? { ProcessInfo.processInfo.environment["UI_FIXTURES"] }
}
