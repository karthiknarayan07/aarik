import XCTest

/// Rules the owner set for the iOS app, as tests. The ones about when a run starts (Add to Queue only queues, Convert
/// Now starts, Start on the Queue starts, a relaunch doesn't start a queue nobody started) live in
/// `RunAndRelaunchTests`; this adds the selection bar's Add to Queue and the wording rule.
@MainActor
final class OwnerRulesTests: AppTestCase {
    private static let toolWords = ["convert", "shrink", "compress"]

    /// Add to Queue from the selection bar queues the video and nothing runs: no progress, Start still offered.
    func testSelectionBarAddToQueueDoesNotStartARun() throws {
        launch()
        open("Photos")
        app.buttons["selectToggle"].firstMatch.tap()
        let tile = tile(named: "clip-long")
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.tap()
        let add = app.buttons["addSelectionToQueue"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        confirmLossIfAsked()
        open("Queue")
        XCTAssertTrue(element(labelContaining: "clip-long").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["startQueue"].firstMatch.waitForExistence(timeout: 10), "no Start on the Queue")
        XCTAssertFalse(runningProgress.waitForExistence(timeout: 4), "Add to Queue started a run")
    }

    // MARK: App-level screens carry no tool name

    /// What a screen says: static text, button and image labels, and navigation titles, left out inside the tool
    /// cards (`tool.*`), where the tool's own name belongs.
    private func words() throws -> [String] {
        let snapshot = try app.snapshot()
        var found: [String] = []
        func walk(_ node: any XCUIElementSnapshot) {
            if node.identifier.hasPrefix("tool.") { return }
            switch node.elementType {
            case .staticText, .button, .image, .navigationBar:
                if !node.label.isEmpty { found.append(node.label) }
                if node.elementType == .navigationBar, !node.identifier.isEmpty { found.append(node.identifier) }
            default: break
            }
            for child in node.children { walk(child) }
        }
        walk(snapshot)
        return found
    }

    private func assertNoToolName(on screen: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for text in try words() {
            for word in Self.toolWords where text.localizedCaseInsensitiveContains(word) {
                XCTFail("\(screen) names a tool: \"\(text)\"", file: file, line: line)
            }
        }
    }

    func testOnboardingNamesNoTool() throws {
        launch(extraArguments: ["-uiTestingFreshOnboarding"], onboarding: true)
        let next = app.buttons["onboarding.continue"]
        for page in 1...3 {
            XCTAssertTrue(next.waitForExistence(timeout: 10))
            try assertNoToolName(on: "Onboarding page \(page)")
            next.tap()
            if page == 2 { sleep(1) }
        }
    }

    func testHomeAndBrowseNameNoTool() throws {
        launch()
        selectTab("Home")
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        sleep(1)
        try assertNoToolName(on: "Home")
        selectTab("Browse", again: true)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool.'")).firstMatch
                .waitForExistence(timeout: 10), "no tool card in Browse")
        try assertNoToolName(on: "Browse")
    }

    func testHomeWithAQueuedVideoNamesNoTool() throws {
        launch()
        queuePhotosFixture()
        open("Home")
        XCTAssertTrue(app.descendants(matching: .any)["home.continue"].firstMatch.waitForExistence(timeout: 15))
        try assertNoToolName(on: "Home with a queued video")
    }
}
