import XCTest

@MainActor
final class ShareHandoffTests: AppTestCase {
    /// A video the share extension (or the App Intent) staged is picked up when the app becomes active, and shows in
    /// the library. The test stages it exactly as the extension does: `<staging>/<uuid>/<name>`.
    func testStagedItemIsPickedUpOnActivation() throws {
        let fixtures = try XCTUnwrap(fixtureDirectory, "UI_FIXTURES isn't set; run scripts/ios-ui-tests.sh")
        launch(autoStart: false)

        let folder = handoffDirectory + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: fixtures + "/handoff-fixture.mov", toPath: folder + "/handoff-fixture.mov")

        XCUIDevice.shared.press(.home)
        app.activate()

        open("Local Files")
        XCTAssertTrue(
            tile(named: "handoff-fixture.mov").waitForExistence(timeout: 30), "the staged video wasn't picked up")
    }
}
