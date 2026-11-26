import XCTest

@MainActor
final class LaunchTests: XCTestCase {
    func testLaunchShowsRoot() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["root"].firstMatch.waitForExistence(timeout: 10))
    }
}
