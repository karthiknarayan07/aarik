import XCTest

/// Every page of the sidebar, in the real app: it opens, shows its key elements, and the window doesn't move or resize.
@MainActor
final class PagesTests: UITestCase {
    func testEveryPageShowsItsKeyElements() async throws {
        try await launch()
        let frame = window.frame
        let pages = allPages()
        XCTAssertGreaterThanOrEqual(pages.count, 11, "The sidebar lists fewer pages than expected")
        for page in pages {
            open(page)
            XCTAssertEqual(window.frame, frame, "The window changed when \(page.title) opened")
            if page.hasInspector {
                XCTAssertTrue(element("inspector").exists, "\(page.title) has no inspector column")
            } else {
                XCTAssertFalse(element("inspector").exists, "\(page.title) shows an inspector column")
            }
        }
    }

    func testHomeShowsTheFixtureHistory() async throws {
        try await launch()
        open(Self.home)
        let card = element("home.card.converted")
        let text = "\(card.label) \(card.value as? String ?? "")"
        XCTAssertTrue(text.contains("12"), "The converted card doesn't count the 12 fixture videos: \(text)")
    }

    func testAskIsHiddenWhenAppleIntelligenceIsUnavailable() async throws {
        try await launch(assistant: false)
        XCTAssertTrue(sidebarRow("Home").waitForExistence(timeout: 20))
        XCTAssertTrue(sidebarRow("Local Files").exists)
        XCTAssertFalse(sidebarRow("Ask").exists, "Ask is listed although the model is unavailable")
    }

    func testTheWindowKeepsItsFrameAtTheMinimumSize() async throws {
        try await launch(size: .minimum)
        let frame = window.frame
        for page in allPages() {
            open(page)
            XCTAssertEqual(window.frame, frame, "The window changed when \(page.title) opened")
        }
    }
}
