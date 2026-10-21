import XCTest

/// Library-level flows added alongside book deletion and the saved quotes
/// screen. Debug builds seed alice.epub on launch whenever the library is
/// empty, so there's always at least one book to work with.
final class LibraryUITests: XCTestCase {
    func testSavedQuotesScreenOpensAndCloses() {
        let app = XCUIApplication()
        app.launch()

        let quotesButton = app.buttons["home-saved-quotes"]
        XCTAssertTrue(quotesButton.waitForExistence(timeout: 5))
        quotesButton.tap()

        XCTAssertTrue(app.navigationBars["Saved Quotes"].waitForExistence(timeout: 5))
        app.buttons["saved-quotes-done"].tap()
        XCTAssertTrue(quotesButton.waitForExistence(timeout: 5))
    }

    func testLongPressDeletesABook() {
        let app = XCUIApplication()
        app.launch()

        let bookTiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
        XCTAssertTrue(bookTiles.firstMatch.waitForExistence(timeout: 10))
        let countBefore = bookTiles.count
        let tile = bookTiles.firstMatch
        let identifier = tile.identifier

        tile.press(forDuration: 1.0)
        let menuDelete = app.buttons["Delete Book"]
        XCTAssertTrue(menuDelete.waitForExistence(timeout: 5))
        menuDelete.tap()

        // The confirmation dialog repeats the action as its own button.
        let confirmDelete = app.buttons["Delete Book"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()

        let deletedTile = app.buttons[identifier]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: deletedTile)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(bookTiles.count, countBefore - 1)
    }
}
