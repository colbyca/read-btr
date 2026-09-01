import XCTest

/// Throwaway spike, not production code (see dev.md §9, phase 2).
///
/// Drives the app to the Navigator/Decoration spike screen and captures a
/// screenshot, since "does the highlight actually render" is a visual
/// question a unit test can't answer.
final class ReadiumNavigatorSpikeUITests: XCTestCase {
    func testNavigatorDecorationRenders() throws {
        let app = XCUIApplication()
        app.launch()

        // "Readium Navigator Spike" now lives inside HomeView's dev-menu
        // (the "ladybug" toolbar item), not as a standalone button.
        let devMenu = app.buttons["dev-menu"]
        XCTAssertTrue(devMenu.waitForExistence(timeout: 5))
        devMenu.reliableTap()

        let spikeButton = app.buttons["Readium Navigator Spike"]
        XCTAssertTrue(spikeButton.waitForExistence(timeout: 5))
        spikeButton.tap()

        // Give the EPUB navigator time to load the resource and the
        // decoration apply() call time to actually paint.
        sleep(3)

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "readium-navigator-spike"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
