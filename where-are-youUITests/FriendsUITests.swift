//
//  FriendsUITests.swift
//  where-are-youUITests
//

import XCTest

final class FriendsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches against the app's fakes (see `LaunchEnvironment` in the app target).
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_FAKE_SERVICES"] = "1"
        app.launchEnvironment["UITEST_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Drags the People sheet up so every row is on screen.
    @MainActor
    private func openFriend(_ id: String, in app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.waitForExistence(timeout: 10) {
            grabber.swipeUp()
        }
        let row = element("friendRow.\(id)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    @MainActor
    func testCreatingAnInviteCodeShowsIt() {
        let app = launchApp()
        let addFriend = app.buttons["addFriendButton"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 10))
        addFriend.tap()

        app.buttons["Create Invite Code"].tap()

        XCTAssertTrue(element("inviteCode", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy Code"].exists)
    }

    @MainActor
    func testAcceptingAPastedCodeAddsAFriend() {
        let app = launchApp()
        app.buttons["addFriendButton"].tap()
        let field = element("inviteCodeField", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // A well-formed code: 43-character token, then a 22-character key ID.
        let token = String(repeating: "A", count: 43)
        field.tap()
        field.typeText("\(token).\(String(repeating: "B", count: 22))")
        app.buttons["Continue"].tap()
        let accept = app.buttons["Accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(app.staticTexts["You're Friends"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()

        XCTAssertTrue(element("friendRow.invited-AAAAAAAA", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testMalformedCodeIsExplained() {
        let app = launchApp()
        app.buttons["addFriendButton"].tap()
        let field = element("inviteCodeField", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.tap()
        field.typeText("not-a-code")
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.alerts["Couldn't Continue"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChangedKeyNoticeCanBeDismissed() {
        let app = launchApp()
        openFriend("LSDLVJH234785", in: app)
        XCTAssertTrue(app.buttons["Compare Codes"].waitForExistence(timeout: 5))

        app.buttons["Dismiss"].tap()

        XCTAssertFalse(app.buttons["Compare Codes"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testMarkingSecurityCodeVerified() {
        let app = launchApp()
        openFriend("QW345DVJjdfe", in: app)
        let securityCode = app.buttons["securityCode"]
        XCTAssertTrue(securityCode.waitForExistence(timeout: 5))
        securityCode.tap()
        XCTAssertTrue(element("securityCodeDigits", in: app).waitForExistence(timeout: 5))

        app.buttons["Mark as Verified"].tap()

        XCTAssertFalse(app.buttons["Mark as Verified"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testRemovingAFriend() {
        let app = launchApp()
        openFriend("798237498DFBRE34", in: app)
        let remove = app.buttons["Remove Friend"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()

        let confirm = app.sheets.buttons["Remove Friend"].exists
            ? app.sheets.buttons["Remove Friend"]
            : app.buttons.matching(identifier: "Remove Friend").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertFalse(element("friendRow.798237498DFBRE34", in: app).waitForExistence(timeout: 3))
    }
}
