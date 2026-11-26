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
        terminateFirst: Bool = false, onboarding: Bool = false
    ) {
        if terminateFirst { app.terminate() }
        var arguments = [
            "-uiTesting", supportDirectory, "-uiTestingHandoff", handoffDirectory,
            "-queue.autoStart", autoStart ? "<true/>" : "<false/>",
        ]
        // The first-launch introduction would cover every test's first screen; only its own test shows it.
        if !onboarding { arguments += ["-onboarding.completed", "<true/>"] }
        if pinSpeed { arguments += ["-performance.speed", "balanced"] }
        if let contentSize { arguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchArguments = arguments + extraArguments
        app.launch()
        XCTAssertTrue(root.waitForExistence(timeout: 30), "The app didn't show its root view")
    }

    var root: XCUIElement { app.descendants(matching: .any)["root"].firstMatch }

    // MARK: Navigation

    /// Where each page lives in the tool's tab bar: the tab, and the segment inside it (if any).
    private static let pages: [String: (tab: String, segment: String?)] = [
        "Overview": ("Overview", nil), "Photos": ("Library", "Photos"), "Videos": ("Library", "Photos"),
        "Files": ("Library", "Files"), "Local Files": ("Library", "Files"), "Queue": ("Queue", "Queue"),
        "Completed": ("Queue", "Completed"),
    ]

    var tabBar: XCUIElement { app.tabBars.firstMatch }

    /// Gets into the tool's tab bar: the app launches on the Tools list, so this opens the tool from it.
    func revealTabs() {
        let anyTool = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool.'")).firstMatch
        for _ in 0..<3 {
            if tabBar.exists, tabBar.isHittable { return }
            if anyTool.waitForExistence(timeout: 3), anyTool.isHittable {
                anyTool.tap()
                _ = tabBar.waitForExistence(timeout: 10)
            }
        }
    }

    /// Taps a tab of the tool's tab bar by its title ("Overview", "Library", "Queue", "Search").
    func selectTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        revealTabs()
        let tab = tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "No \(title) tab", file: file, line: line)
        if !tab.isSelected { tab.tap() }
    }

    /// Opens one of Convert's pages ("Overview", "Photos", "Files", "Queue", "Completed").
    func open(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let place = Self.pages[page] else {
            XCTFail("No page called \(page)", file: file, line: line)
            return
        }
        selectTab(place.tab, file: file, line: line)
        guard let segment = place.segment else { return }
        let button = app.segmentedControls.buttons[segment].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "No \(segment) segment", file: file, line: line)
        if !button.isSelected { button.tap() }
    }

    /// Opens Settings from the Overview's toolbar.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        open("Overview", file: file, line: line)
        let settings = app.buttons["settings"].firstMatch
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

    /// Opens Photos, taps the named fixture (which opens its page, with a zoom) and adds it to the queue there.
    func queuePhotosFixture(
        _ name: String = AppTestCase.photosFixture, file: StaticString = #filePath, line: UInt = #line
    ) {
        open("Photos", file: file, line: line)
        let tile = tile(named: name)
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name) isn't in the Photos grid", file: file, line: line)
        scrollToHittable(tile)
        tile.tap()
        let add = app.buttons["detail.addToQueue"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "\(name) didn't open its page", file: file, line: line)
        if !add.isEnabled {
            dump("Add to Queue disabled on the video's page")
        }
        XCTAssertTrue(add.isEnabled, "Add to Queue stayed disabled on the video's page", file: file, line: line)
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
