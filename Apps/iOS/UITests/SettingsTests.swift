import XCTest

@MainActor
final class SettingsTests: AppTestCase {
    private func closeSettings() {
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(root.waitForExistence(timeout: 5))
    }

    /// The speed menu is one button labelled "Conversion Speed, <current choice>".
    private var speedPicker: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Conversion Speed'")).firstMatch
    }

    private var currentSpeed: String {
        speedPicker.label.replacingOccurrences(of: "Conversion Speed, ", with: "")
    }

    func testSettingsShowsTheIOSOptionsOnly() throws {
        launch()
        openSettings()
        XCTAssertTrue(
            app.switches.matching(NSPredicate(format: "label == 'Start the Queue Automatically'")).firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertTrue(speedPicker.exists)
        XCTAssertFalse(element(labelContaining: "Sparkle").exists)
        XCTAssertFalse(element(labelContaining: "Menu Bar").exists)
        XCTAssertFalse(element(labelContaining: "Trash").exists)
        closeSettings()
    }

    /// A choice made in Settings is kept across a relaunch. Whichever of Quiet and Balanced is current switches to the
    /// other, and the test puts it back, so it needs no particular starting state.
    func testChangedSpeedIsKeptAcrossRelaunch() throws {
        launch(pinSpeed: false)
        openSettings()
        XCTAssertTrue(speedPicker.waitForExistence(timeout: 10))
        let original = currentSpeed == "Quiet" ? "Quiet" : "Balanced"
        let changed = original == "Quiet" ? "Balanced" : "Quiet"
        func choose(_ name: String) {
            speedPicker.tap()
            let option = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5), "No \(name) option")
            option.tap()
            XCTAssertTrue(
                speedPicker.label.hasSuffix(name), "the picker didn't change to \(name): \(speedPicker.label)")
        }
        choose(changed)
        closeSettings()

        launch(pinSpeed: false, terminateFirst: true)
        openSettings()
        XCTAssertTrue(speedPicker.waitForExistence(timeout: 10))
        XCTAssertEqual(currentSpeed, changed, "the speed wasn't kept")
        choose(original)
        closeSettings()
    }
}
