import XCTest

/// `LayoutAudit` on every page, at the default and the minimum window size, with the inspector open and closed.
@MainActor
final class LayoutTests: UITestCase {
    func testNoOverlapsAtTheDefaultSize() async throws {
        try await audit(size: .standard)
    }

    func testNoOverlapsAtTheMinimumSize() async throws {
        try await audit(size: .minimum)
    }

    private func audit(size: WindowSize) async throws {
        try await launch(size: size)
        for page in allPages() {
            open(page)
            for inspectorOpen in page.hasInspector ? [true, false] : [false] {
                if page.hasInspector { setInspector(open: inspectorOpen) }
                let name = "\(page.title), \(size), inspector \(inspectorOpen ? "open" : "closed")"
                XCTContext.runActivity(named: name) { _ in
                    LayoutAudit.assertNoOverlaps(in: window)
                }
            }
            // The next page starts from the default state.
            if page.hasInspector { setInspector(open: true) }
        }
    }
}
