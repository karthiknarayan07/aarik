import XCTest

/// A screenshot of the real window for every page at both window sizes, compared with `References/`. The pixels are
/// what catches what the accessibility tree can't see: chart axis labels over bars, clipped text, a column that
/// changed width. Record with `scripts/record-mac-references.sh` and look at every image before committing it.
@MainActor
final class ReferenceScreenshotTests: UITestCase {
    func testPagesAtTheDefaultSize() async throws {
        try await compare(size: .standard)
    }

    func testPagesAtTheMinimumSize() async throws {
        try await compare(size: .minimum)
    }

    private func compare(size: WindowSize) async throws {
        try await launch(size: size)
        for page in allPages() {
            open(page)
            ReferenceImages.assertMatches(
                window.screenshot(), named: "\(page.slug)-\(size)", in: self)
        }
    }
}
