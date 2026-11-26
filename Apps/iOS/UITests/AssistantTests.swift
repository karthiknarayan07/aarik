import XCTest

/// The Ask tab: the empty state and a scripted conversation (`-AssistantDemo`, a Debug-only fake model that touches
/// no library or queue) with a confirmation card, where Cancel must change nothing.
@MainActor
final class AssistantTests: AppTestCase {
    private func ids(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func ask(_ text: String) {
        let field = app.textFields["assistant.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no composer")
        field.tap()
        field.typeText(text)
        app.buttons["assistant.send"].tap()
    }

    func testAskTabShowsItsEmptyStateWithSuggestions() throws {
        launch(autoStart: false, extraArguments: ["-AssistantDemo"])
        selectTab("Ask")
        XCTAssertTrue(ids("assistant.empty").waitForExistence(timeout: 15), "no empty state in Ask")
        XCTAssertTrue(app.buttons["Find My Biggest Videos"].exists, "no suggestion chip")
        XCTAssertTrue(app.textFields["assistant.composer"].exists, "no composer")
    }

    func testConversationWithAConfirmCardAndCancelChangesNothing() throws {
        launch(autoStart: false, extraArguments: ["-AssistantDemo"])
        selectTab("Ask")
        ask("Queue them")

        XCTAssertTrue(
            ids("assistant.message.user").waitForExistence(timeout: 10), "the question didn't show in the chat")
        XCTAssertTrue(ids("assistant.confirmation").waitForExistence(timeout: 20), "no confirmation card")
        XCTAssertTrue(element(labelContaining: "Convert 14 Videos").exists)
        let cancel = app.buttons["assistant.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.confirm"].exists)

        cancel.tap()
        let status = ids("assistant.confirmationStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Cancel left the card pending")
        XCTAssertTrue(status.label.contains("Cancelled"), "the card reads \(status.label)")
        XCTAssertFalse(app.buttons["assistant.confirm"].exists, "Confirm is still offered after Cancel")
        // The scripted model's canned closing line is not evidence either way; the tool's own row is.
        XCTAssertFalse(element(labelContaining: "Queued Videos").exists, "Cancel ran the tool")
    }

    func testConfirmRunsTheAction() throws {
        launch(autoStart: false, extraArguments: ["-AssistantDemo"])
        selectTab("Ask")
        ask("Queue them")
        let confirm = app.buttons["assistant.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "no confirmation card")
        confirm.tap()
        XCTAssertTrue(
            element(labelContaining: "14 videos are in the queue").waitForExistence(timeout: 15),
            "Confirm didn't run the action")
    }

    func testAskTabIsHiddenWhenTheAssistantIsUnavailable() throws {
        launch(autoStart: false, extraArguments: ["-uiTestingAssistant", "unavailable"])
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertTrue(tabBar.buttons["Home"].exists)
        XCTAssertFalse(
            tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask'")).firstMatch.exists,
            "Ask showed without Apple Intelligence")
    }
}
