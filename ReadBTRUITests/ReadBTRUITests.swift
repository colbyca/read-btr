import XCTest

final class ReadBTRUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Book"].exists)
    }

    func testAddBookOpensFileImporter() {
        let app = XCUIApplication()
        app.launch()

        let screenshotBefore = XCTAttachment(screenshot: app.screenshot())
        screenshotBefore.name = "home-empty-library"
        screenshotBefore.lifetime = .keepAlways
        add(screenshotBefore)

        app.buttons["Add Book"].tap()

        // The system document picker is a separate process/UI; assert on
        // its "Cancel" button rather than any ReadBTR-owned element to
        // confirm `.fileImporter` actually presented it.
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))

        let screenshotPicker = XCTAttachment(screenshot: app.screenshot())
        screenshotPicker.name = "file-importer-presented"
        screenshotPicker.lifetime = .keepAlways
        add(screenshotPicker)

        app.buttons["Cancel"].tap()
    }
}
