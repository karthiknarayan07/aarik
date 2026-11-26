import XCTest

@MainActor
final class FilesImportTests: AppTestCase {
    /// Files import goes through the system document picker (it runs in its own process but shows in the app's UI
    /// hierarchy). `scripts/ios-ui-tests.sh` puts `files-fixture.mov` in the app's Documents folder, which the picker
    /// lists under On My iPhone, in a folder named after the app.
    func testImportFromFilesAddsTheVideoToLocalFiles() throws {
        launch(autoStart: false)
        open("Local Files")
        let add = app.buttons["Add Files…"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let browse = app.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "the document picker didn't open")
        browse.tap()

        // Browse opens on the locations list the first time and in the last folder after that.
        let onMyPhone = app.cells.matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
        if onMyPhone.waitForExistence(timeout: 3) { onMyPhone.tap() }
        // On My iPhone's only folder is the app's own.
        let folder = app.cells.matching(NSPredicate(format: "label CONTAINS ' item'")).firstMatch
        if !folder.waitForExistence(timeout: 15) { dump("files picker without the app folder") }
        XCTAssertTrue(folder.exists, "no app folder under On My iPhone")
        folder.tap()

        let file = app.cells.matching(NSPredicate(format: "label CONTAINS 'files-fixture'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), "files-fixture isn't in the folder")
        file.tap()
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 3), open.isEnabled { open.tap() }

        XCTAssertTrue(
            tile(named: AppTestCase.filesFixture).waitForExistence(timeout: 30),
            "the imported video isn't in Local Files")
    }
}
