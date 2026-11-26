import XCTest

/// Drives the Ask tab against the REAL on-device Apple Intelligence model (no `-AssistantDemo`). Slow and dependent on the
/// device, so it only runs when `RUN_REAL_AI=1` is set (`TEST_RUNNER_RUN_REAL_AI=1 xcodebuild test ...`); CI and the
/// normal suite skip it. Needs generated clips in the Simulator's Photos library and Photos access granted (see
/// `scripts/ios-ui-tests.sh`); it asserts that the chat answers, shows its tool calls, and that a cancelled
/// confirmation queues nothing. What the model actually said is printed as `REAL-AI-REPLY` lines and kept as attachments.
@MainActor
final class RealAssistantSmokeTests: AppTestCase {
    private var composer: XCUIElement { app.textFields["Ask Anything"].firstMatch }
    private var sendButton: XCUIElement { app.buttons["Send"].firstMatch }
    private var stopButton: XCUIElement { app.buttons["Stop"].firstMatch }
    private var replies: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Assistant said: '"))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launches and opens Ask; Apple Intelligence can take a while to report availability after a boot, so wait up to
    /// 90 s and relaunch once.
    private func openAsk() throws {
        for attempt in 0..<2 {
            launch(autoStart: false)
            let ask = tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask'")).firstMatch
            if ask.waitForExistence(timeout: 90) {
                ask.tap()
                XCTAssertTrue(composer.waitForExistence(timeout: 15), "The Ask tab didn't show its composer")
                return
            }
            if attempt == 0 { app.terminate() }
        }
        attachScreenshot("no-ask-tab")
        throw XCTSkip("The Ask tab never appeared: Apple Intelligence isn't available on this Simulator")
    }

    /// Sends `text` and waits for the answer to finish streaming (Stop turns back into Send).
    @discardableResult
    private func ask(_ text: String, timeout: TimeInterval = 180) -> String {
        let before = replies.count
        composer.tap()
        composer.typeText(text)
        let bubble = element(labelContaining: "You said: \(text)")
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        sendButton.tap()
        _ = bubble.waitForExistence(timeout: 10)
        let sent = bubble.exists
        if !sent {
            attachScreenshot("not-sent")
            dump("not sent")
        }
        XCTAssertTrue(sent, "\(text) wasn't sent")
        _ = stopButton.waitForExistence(timeout: 20)
        // A confirmation card waiting for a tap shows Send again (the answer isn't being written), so a card ends the
        // wait too; it is cancelled below, after which the model answers once more.
        let cancel = app.buttons["Cancel"].firstMatch
        let settled = NSPredicate { [stopButton] _, _ in !stopButton.exists || cancel.exists }
        let done = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(
            XCTWaiter().wait(for: [done], timeout: timeout), .completed, "The model never finished answering \(text)")
        if cancel.exists {
            print("REAL-AI-CONFIRMATION-CARD: \(element(labelContaining: "Convert").label)")
            attachScreenshot("3-convert-confirmation")
            cancel.tap()
            XCTAssertTrue(
                element(labelContaining: "Cancelled").waitForExistence(timeout: 5),
                "The card didn't show it was cancelled")
            _ = stopButton.waitForExistence(timeout: 10)
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: stopButton)
            XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 120), .completed, "Stuck after Cancel")
        }
        _ = sendButton.waitForExistence(timeout: 5)
        let latest = replies.count > before ? replies.element(boundBy: replies.count - 1).label : ""
        print("REAL-AI-REPLY [\(text)]: \(latest)")
        return latest
    }

    private func toolRows() -> [String] {
        let words = ["Searched", "Estimated", "Explained", "Listed", "Checked"]
        let format = words.map { "label CONTAINS[c] '\($0)'" }.joined(separator: " OR ")
        return app.descendants(matching: .any).matching(NSPredicate(format: format)).allElementsBoundByIndex.map(
            \.label)
    }

    func testRealModelAnswersSearchesAndNeverActsWithoutConfirmation() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_REAL_AI"] == "1", "Set RUN_REAL_AI=1 to run against the real model"
        )
        try openAsk()

        // 1. Savings.
        let savings = ask("How much space can I save?")
        attachScreenshot("1-space-savings")
        print("REAL-AI-TOOLS-1: \(toolRows())")
        let text = savings.replacingOccurrences(of: "Assistant said: ", with: "")
        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty reply to the savings question")

        // 2. A search shows a tool-call row.
        ask("Find my biggest videos")
        attachScreenshot("2-find-biggest")
        let tools = toolRows()
        print("REAL-AI-TOOLS-2: \(tools)")
        XCTAssertTrue(
            tools.contains { $0.localizedCaseInsensitiveContains("Searched Library") },
            "No \"Searched Library\" tool-call row appeared; rows: \(tools)")

        // 2b. Long-pressing the last reply offers Copy.
        let lastReply = replies.element(boundBy: replies.count - 1)
        XCTAssertTrue(lastReply.exists, "No reply to long-press")
        lastReply.press(forDuration: 1.2)
        let copy = app.buttons["Copy"].firstMatch
        let offered = copy.waitForExistence(timeout: 5)
        attachScreenshot("2b-copy-menu")
        XCTAssertTrue(offered, "Long-pressing the reply didn't offer Copy")
        if offered { copy.tap() }

        // 3. An action asks first; cancel and check nothing was queued.
        ask("Convert my biggest videos")
        attachScreenshot("4-after-cancel")
        open("Queue")
        XCTAssertTrue(
            app.staticTexts["Queue Is Empty"].waitForExistence(timeout: 10),
            "Something was queued without a confirmation")
        attachScreenshot("5-queue-empty")
    }
}
