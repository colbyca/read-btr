import XCTest

/// Drives the real Normal reading screen end to end (design-roadmap.md
/// §6.5) against the DEBUG-only seeded `alice.epub` book — confirms the
/// stock Readium navigator actually renders content and that the
/// tap-at-top-of-screen toolbar trigger works, both visual/interaction
/// questions a unit test can't answer on its own.
final class NormalReadingViewUITests: XCTestCase {
    func testNormalReadingRendersAndTopTapRevealsToolbar() throws {
        let app = XCUIApplication()
        app.launch()

        // Fresh, known starting position every run — mirrors
        // RSVPViewUITests/GuidedReadingViewUITests.
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

        let normalOption = app.buttons["Normal"]
        XCTAssertTrue(normalOption.waitForExistence(timeout: 5))
        normalOption.tap()

        let navigator = app.descendants(matching: .any)["normal-reading-navigator"]
        XCTAssertTrue(navigator.waitForExistence(timeout: 10), "the Normal reading navigator never mounted")

        // The SwiftUI wrapper mounts as soon as the navigator is
        // constructed (Normal mode's `loadState` doesn't wait on anything
        // else, unlike Guided Reading) — but the WKWebView itself still
        // needs a beat to actually finish loading the resource before it
        // reliably routes taps.
        Thread.sleep(forTimeInterval: 2.0)
        attach(app, name: "normal-reading-content")

        // Tap inside the navigator's 80pt top zone, but not right at the
        // very edge — a tap in the top few points overlaps the status
        // bar/Dynamic Island's own touch-interception zone (confirmed
        // empirically: a tap at 2% down never reached `didTapAt` at all;
        // one safely below that, still well inside the 80pt zone, does).
        // Anchored off the *app's* coordinate space, not the navigator
        // element's own — a `UIViewControllerRepresentable`-hosted
        // element's own frame isn't reliably reported to the accessibility
        // tree, but the app window's frame is.
        let topPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07))
        let chapterSelectButton = app.buttons["normal-reading-chapter-select"]
        for _ in 0..<5 where !chapterSelectButton.exists {
            topPoint.tap()
            _ = chapterSelectButton.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(chapterSelectButton.exists)
        attach(app, name: "normal-reading-toolbar-shown")

        // Chapter select sheet opens from the toolbar, same as RSVP/Guided
        // Reading's identical toolbar entry.
        chapterSelectButton.tap()
        XCTAssertTrue(app.navigationBars["Chapters"].waitForExistence(timeout: 5))
        attach(app, name: "normal-reading-chapter-select-sheet")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
