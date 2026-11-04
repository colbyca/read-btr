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

        // The confirmation dialog has its own "Delete Book" button. SwiftUI
        // exposes it twice in the accessibility tree (a button nested in a
        // button, same identifier), so tap the first match by identifier.
        let confirmDelete = app.buttons["confirm-delete-book"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()

        let deletedTile = app.buttons[identifier]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: deletedTile)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(bookTiles.count, countBefore - 1)
    }

    func testCreatesACollectionAndOpensIt() {
        let app = XCUIApplication()
        app.launch()

        let bookTiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
        XCTAssertTrue(bookTiles.firstMatch.waitForExistence(timeout: 10))

        app.buttons["home-add"].tap()
        let addCollection = app.buttons["add-collection"].firstMatch
        XCTAssertTrue(addCollection.waitForExistence(timeout: 5))
        addCollection.tap()

        let name = "Test Series \(Int.random(in: 1000...9999))"
        let nameField = app.textFields["new-collection-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText(name)

        app.buttons["new-collection-add-books"].tap()
        let firstPick = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pick-book-'")).firstMatch
        XCTAssertTrue(firstPick.waitForExistence(timeout: 5))
        firstPick.tap()
        app.buttons["pick-books-confirm"].tap()

        let create = app.buttons["new-collection-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()

        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()

        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["collection-book-0"].waitForExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "collection-detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Clean up so repeated runs don't pile up collections.
        app.buttons["collection-more"].tap()
        let delete = app.buttons["collection-delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["confirm-delete-collection"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
    }
}
