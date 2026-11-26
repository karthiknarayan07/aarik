import XCTest

/// The pages of the sidebar and what each one must show, by accessibility identifier.
extension UITestCase {
    struct Page {
        let title: String
        /// Identifiers that exist once the page has loaded.
        let ready: [String]
        /// Whether the inspector column can be shown here (Home has none).
        let hasInspector: Bool

        var slug: String { title.replacingOccurrences(of: " ", with: "") }
    }

    /// The media-type filters the sidebar may list under Local Files, depending on what the library holds.
    private static let filterTitles = [
        "Dolby Vision", "HDR", "4K", "Cinematic", "Slo-mo", "Spatial", "Edited", "SDR",
    ]

    private static let library = ["localFiles.grid", "localFiles.savingsHeader", "localFiles.storageBar"]

    static let home = Page(
        title: "Home",
        ready: [
            "home.summary", "home.ring", "home.card.couldFree", "home.card.saved", "home.card.converted",
            "home.card.biggestGroup", "home.chart.beforeAfter", "home.chart.groupSavings",
            "home.chart.savedOverTime", "home.chart.throughput", "home.group.biggestGroups", "home.group.sources",
        ], hasInspector: false)

    /// Every page of the sidebar, in order; the filters are the ones the sidebar lists right now.
    func allPages(includingAsk: Bool = true) -> [Page] {
        var pages = [Self.home]
        if includingAsk { pages.append(Page(title: "Ask", ready: ["assistant.composer"], hasInspector: true)) }
        pages.append(Page(title: "Photos", ready: ["photos.accessPrompt"], hasInspector: true))
        pages.append(Page(title: "Local Files", ready: Self.library, hasInspector: true))
        for title in Self.filterTitles where sidebarRow(title).exists {
            pages.append(Page(title: title, ready: Self.library, hasInspector: true))
        }
        pages += [
            Page(title: "Queue", ready: ["queue.empty"], hasInspector: true),
            Page(title: "Completed", ready: ["completed.summary", "completed.list"], hasInspector: true),
            Page(title: "Kept as Is", ready: ["keptAsIs.list"], hasInspector: true),
            Page(title: "Failed", ready: ["failed.list"], hasInspector: true),
        ]
        return pages
    }

    // MARK: Navigation

    /// Selects a sidebar page and waits until its key elements are there and it has stopped changing.
    func open(_ page: Page, file: StaticString = #filePath, line: UInt = #line) {
        let row = sidebarRow(page.title)
        let hasRow = row.waitForExistence(timeout: 20)
        XCTAssertTrue(hasRow, "No sidebar row \(page.title)", file: file, line: line)
        if !hasRow { return }
        row.click()
        for identifier in page.ready {
            let found = element(identifier).waitForExistence(timeout: 30)
            XCTAssertTrue(found, "\(page.title) shows no \(identifier)", file: file, line: line)
            if !found { return }
        }
        if page.title == "Home" {
            let summary = element("home.summary")
            let text = "\(summary.label) \(summary.value as? String ?? "")"
            XCTAssertTrue(
                text.contains("Updated now"), "Home doesn't say \"Updated now\": \(text)", file: file, line: line)
        }
        settle()
    }

    /// Moves the pointer off the window (so no row shows its hover state) and lets animations finish.
    func settle() {
        window.coordinate(withNormalizedOffset: CGVector(dx: 1.05, dy: 1.05)).hover()
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Shows or hides the inspector column with its toolbar button.
    func setInspector(open wanted: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let button = element("toolbar.inspector")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No inspector button", file: file, line: line)
        if element("inspector").exists != wanted {
            button.click()
            let changed =
                wanted ? element("inspector").waitForExistence(timeout: 10) : waitForGone(element("inspector"))
            XCTAssertTrue(changed, "The inspector didn't \(wanted ? "open" : "close")", file: file, line: line)
        }
        settle()
    }

    func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: element)], timeout: timeout) == .completed
    }
}
