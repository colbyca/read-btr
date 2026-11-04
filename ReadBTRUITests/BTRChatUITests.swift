import XCTest

/// Opens the BTR chat from RSVP with a stubbed AI provider (DEBUG-only
/// `-uitest-stub-ai` launch argument) and checks the passage, word
/// selection, and a rendered Markdown reply.
final class BTRChatUITests: XCTestCase {
    func testOpensChatFromRSVPAndShowsAReply() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-uitest-stub-ai")
        app.launch()

        let devMenu = app.buttons["dev-menu"]
        XCTAssertTrue(devMenu.waitForExistence(timeout: 5))
        devMenu.reliableTap()
        app.buttons["Reset Library"].tap()
        devMenu.reliableTap()
        app.buttons["Seed alice.epub"].tap()

        let bookButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'")).firstMatch
        XCTAssertTrue(bookButton.waitForExistence(timeout: 5))
        bookButton.tap()
        let rsvpOption = app.buttons["RSVP"]
        XCTAssertTrue(rsvpOption.waitForExistence(timeout: 5))
        rsvpOption.tap()

        let word = app.staticTexts["rsvp-current-word"]
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        word.press(forDuration: 1.0)

        let btr = app.buttons["btr-tooltip-btr"]
        XCTAssertTrue(btr.waitForExistence(timeout: 5))
        btr.tap()

        XCTAssertTrue(app.navigationBars["BTR Chat"].waitForExistence(timeout: 5))
        let firstWord = app.buttons["btr-chat-word-0"]
        XCTAssertTrue(firstWord.waitForExistence(timeout: 10))
        firstWord.tap()
        attach(app, name: "btr-chat-opened")

        let input = app.textFields["btr-chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Who is Alice?")
        app.buttons["btr-chat-send"].tap()

        XCTAssertTrue(app.staticTexts["Who is Alice?"].waitForExistence(timeout: 5))
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'curious heroine'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        attach(app, name: "btr-chat-reply")

        app.buttons["btr-chat-back"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 5))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
