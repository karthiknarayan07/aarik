import XCTest

/// Selecting a page must put its content in place, not slide it: the detail column keeps its width across page
/// switches, so nothing reflows while the inspector column comes or goes, and the window itself never resizes. Samples
/// the window frame and the page's key elements for half a second after the click and requires them to stay where they
/// were (the elements' x and width from the first sample).
@MainActor
final class TransitionTests: UITestCase {
    /// Milliseconds after the click at which the frames are read (each read itself takes a few tens of ms).
    private let sampleTimes = [0, 100, 250, 500]
    private let tolerance: CGFloat = 1

    /// What to follow on a page: the first of its key elements and, on Home, the hero, a stat card and a chart.
    private func tracked(_ page: Page) -> [String] {
        page.title == "Home"
            ? ["home.summary", "home.card.couldFree", "home.chart.beforeAfter"] : [page.ready[0]]
    }

    func testPagesDoNotMoveWhenSelected() async throws {
        try await launch()
        let pages = allPages()
        guard let home = pages.first else { return }
        // Every other page to Home, and Home to every other page.
        for page in pages.dropFirst() {
            open(page)
            assertStaysPut(selecting: home, from: page)
            assertStaysPut(selecting: page, from: home)
        }
    }

    private var windowFrame: CGRect { window.frame }

    private func assertStaysPut(
        selecting page: Page, from previous: Page, file: StaticString = #filePath, line: UInt = #line
    ) {
        if previous.title != "Home" || page.title == "Home" { open(previous) } else { open(Self.home) }
        let row = sidebarRow(page.title)
        let identifiers = tracked(page)
        let start = Date()
        row.click()
        var baseline: [String: CGRect] = [:]
        let windowBefore = windowFrame
        for time in sampleTimes {
            let wait = Double(time) / 1000 - Date().timeIntervalSince(start)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            XCTAssertEqual(
                windowFrame, windowBefore,
                "The window resized \(time) ms after selecting \(page.title) from \(previous.title)", file: file,
                line: line)
            for identifier in identifiers {
                let found = element(identifier)
                guard found.exists else { continue }
                let frame = found.frame
                guard let first = baseline[identifier] else {
                    baseline[identifier] = frame
                    continue
                }
                let moved = abs(frame.minX - first.minX) > tolerance || abs(frame.width - first.width) > tolerance
                XCTAssertFalse(
                    moved,
                    "\(identifier) moved after selecting \(page.title) from \(previous.title): \(first) at first, \(frame) at \(time) ms",
                    file: file, line: line)
            }
        }
        XCTAssertFalse(baseline.isEmpty, "\(page.title) showed none of \(identifiers)", file: file, line: line)
    }
}
