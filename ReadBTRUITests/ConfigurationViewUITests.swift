import XCTest

/// Drives the real Settings screen end to end (design-roadmap.md §6.2) —
/// confirms the global-mode entry point (Home's gear icon) actually opens
/// the form, renders its sections, and that a toggle's state survives
/// closing and reopening the sheet, which a plain unit test can't verify
/// since it never mounts real SwiftUI `Form`/`Toggle` machinery.
final class ConfigurationViewUITests: XCTestCase {
    func testGlobalSettingsOpenAndPersistAToggle() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsButton = app.buttons["home-settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        attach(app, name: "settings-opened")

        // The AI section is well below the fold — Form/List rows are lazily
        // rendered, so the toggle doesn't exist in the accessibility tree
        // until scrolled into view.
        let aiToggle = app.switches["Enable AI Features"]
        scrollUntilExists(aiToggle, in: app)
        XCTAssertTrue(aiToggle.exists)
        let initialValue = aiToggle.value as? String
        attach(app, name: "before-tap")
        // The switch control itself sits at the row's right edge — a plain
        // center-of-row tap (`reliableTap()`'s usual (0.5, 0.5)) didn't
        // register at all here, confirmed via before/after screenshots
        // being pixel-identical.
        aiToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, name: "after-tap")
        let toggledValue = aiToggle.value as? String
        XCTAssertNotEqual(initialValue, toggledValue, "toggling the switch didn't change its value")

        // Scrolling down to the AI section pushes the navigation bar (and its
        // Done button) off screen, so scroll back up before closing.
        let doneButton = app.buttons["settings-done"]
        for _ in 0..<8 where !doneButton.isHittable {
            app.swipeDown()
        }
        doneButton.tap()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))

        // Reopen — the toggle should have kept its new state.
        settingsButton.tap()
        let reopenedToggle = app.switches["Enable AI Features"]
        scrollUntilExists(reopenedToggle, in: app)
        XCTAssertTrue(reopenedToggle.exists)
        XCTAssertEqual(reopenedToggle.value as? String, toggledValue)
        attach(app, name: "settings-reopened-toggle-persisted")
    }

    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
