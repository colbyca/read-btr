import XCTest

/// Drives the real RSVP screen end to end (design-roadmap.md §6.3) against
/// the DEBUG-only seeded `alice.epub` book, capturing screenshots at each
/// state — visual/interaction behavior a unit test can't verify on its own.
final class RSVPViewUITests: XCTestCase {
    func testRSVPPlaybackAndToolbarFlow() throws {
        let app = XCUIApplication()
        app.launch()

        // The app's SwiftData store persists across test runs in the same
        // simulator, so a book seeded in an earlier run may already have a
        // position saved partway through the book. Reset + reseed here so
        // this test starts from a known, fresh index-0 position every time.
        let devMenu = app.buttons["dev-menu"]
        XCTAssertTrue(devMenu.waitForExistence(timeout: 5))
        devMenu.reliableTap()
        app.buttons["Reset Library"].tap()
        devMenu.reliableTap()
        app.buttons["Seed alice.epub"].tap()

        let bookButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'book-'")
        ).firstMatch
        XCTAssertTrue(bookButton.waitForExistence(timeout: 5))
        bookButton.tap()

        let rsvpOption = app.buttons["RSVP"]
        XCTAssertTrue(rsvpOption.waitForExistence(timeout: 5))
        rsvpOption.tap()

        let word = app.staticTexts["rsvp-current-word"]
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        attach(app, name: "rsvp-paused-initial")

        // Tap outside the word *immediately*, from the deterministic
        // index-0 starting position — isolates whether the scrubber centers
        // correctly on first appearance from any autoplay-timing noise.
        app.otherElements["rsvp-background"].tap()
        XCTAssertTrue(app.buttons["rsvp-chapter-select"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, name: "rsvp-toolbar-shown-from-index-zero")

        // Now exercise play -> auto-advance -> pause, and confirm the
        // scrubber follows to the *current* (now-advanced) index rather
        // than showing a stale one. Tapping the word resumes play (and,
        // per RSVPViewModel.play(), hides the toolbar automatically).
        word.tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.otherElements["rsvp-background"].tap() // pause + show toolbar again
        XCTAssertTrue(app.buttons["rsvp-chapter-select"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, name: "rsvp-toolbar-shown-after-playback")

        // Chapter select sheet opens from the toolbar.
        app.buttons["rsvp-chapter-select"].tap()
        XCTAssertTrue(app.navigationBars["Chapters"].waitForExistence(timeout: 5))
        attach(app, name: "rsvp-chapter-select-sheet")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
