import XCTest

/// Drives the real Guided Reading screen end to end (design-roadmap.md
/// §6.4) against the DEBUG-only seeded `alice.epub` book — specifically a
/// regression guard for the "infinite loading screen" bug: the navigator's
/// own view has to be mounted and laid out before `GuidedReadingViewModel`
/// can ever leave `.loading`, so this asserts the loading overlay actually
/// clears, not just that the screen opened.
final class GuidedReadingViewUITests: XCTestCase {
    func testGuidedReadingLoadsAndHighlightsRealContent() throws {
        let app = XCUIApplication()
        app.launch()

        // Fresh, known starting position every run — mirrors RSVPViewUITests.
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

        let guidedOption = app.buttons["Guided Reading"]
        XCTAssertTrue(guidedOption.waitForExistence(timeout: 5))
        guidedOption.tap()

        let navigator = app.descendants(matching: .any)["guided-reading-navigator"]
        XCTAssertTrue(navigator.waitForExistence(timeout: 10), "the Guided Reading navigator never mounted")
        attach(app, name: "guided-reading-just-mounted")

        // Give the WebView time to load the resource, lay out, and let
        // GuidedReadingViewModel's onViewReady -> finishLoadingOnceViewIsReady
        // chain resolve real line rects.
        let loadingOverlay = app.descendants(matching: .any)["guided-reading-loading"]
        let clearedLoading = NSPredicate(format: "exists == false")
        expectation(for: clearedLoading, evaluatedWith: loadingOverlay, handler: nil)
        waitForExpectations(timeout: 10)

        XCTAssertFalse(loadingOverlay.exists, "stuck on the loading overlay — the reported infinite-loading bug")

        // Let any post-.ready resize (toolbar hiding once loadState settles)
        // and its onViewResized -> refreshLinesAfterResize round trip finish
        // before the "final" screenshot, so it reflects steady state.
        Thread.sleep(forTimeInterval: 2.0)
        attach(app, name: "guided-reading-ready")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
