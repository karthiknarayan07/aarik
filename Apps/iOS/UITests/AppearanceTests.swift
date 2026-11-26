import XCTest

/// The browse-and-queue flow in light and dark, at the default Dynamic Type size and at AX3 (the third accessibility
/// size). It looks for labels, not positions, so a layout that truncates or overlaps at large sizes still has to keep
/// every control reachable. Screenshots are attached for review.
@MainActor
final class AppearanceTests: AppTestCase {
    private static let defaultSize = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
        try await super.tearDown()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func runFlow(appearance: XCUIDevice.Appearance, contentSize: String, label: String) {
        XCUIDevice.shared.appearance = appearance
        launch(autoStart: false, contentSize: contentSize)
        attach("\(label) start")
        queuePhotosFixture("clip-long.mov")
        attach("\(label) photos")
        open("Queue")
        XCTAssertTrue(
            element(labelContaining: "clip-long").waitForExistence(timeout: 15), "\(label): the job isn't queued")
        attach("\(label) queue")
        openSettings()
        attach("\(label) settings")
    }

    func testLightDefaultSize() { runFlow(appearance: .light, contentSize: Self.defaultSize, label: "light default") }
    func testDarkDefaultSize() { runFlow(appearance: .dark, contentSize: Self.defaultSize, label: "dark default") }
    func testLightAX3() { runFlow(appearance: .light, contentSize: Self.ax3, label: "light AX3") }
    func testDarkAX3() { runFlow(appearance: .dark, contentSize: Self.ax3, label: "dark AX3") }
}
