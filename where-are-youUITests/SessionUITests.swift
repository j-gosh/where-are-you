//
//  SessionUITests.swift
//  where-are-youUITests
//

import XCTest

final class SessionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches against the app's fakes (see `LaunchEnvironment` in the app target).
    @MainActor
    private func launchApp(session: String? = nil, locationAuthorization: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_FAKE_SERVICES"] = "1"
        app.launchEnvironment["UITEST_RESET_STATE"] = "1"
        app.launchEnvironment["UITEST_SESSION"] = session
        app.launchEnvironment["UITEST_LOCATION_AUTH"] = locationAuthorization
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        // A button query: the identifier also reaches the avatar inside the button.
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
    }

    @MainActor
    func testSignedOutShowsSignInWithApple() {
        let app = launchApp(session: "signedOut")

        XCTAssertTrue(element("signInWithApple", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testNewUserCreatesProfileThenSeesMap() {
        let app = launchApp(session: "newUser")
        let nameField = element("profileNameField", in: app)
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "An empty name can't be saved")

        nameField.tap()
        nameField.typeText("Jamie Rivera")
        app.buttons["Continue"].tap()

        XCTAssertTrue(element("friendRow.798237498DFBRE34", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testEditedProfileNameShowsInSettings() {
        let app = launchApp()
        openSettings(in: app)
        element("editProfile", in: app).tap()
        let nameField = element("profileNameField", in: app)
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))

        // The tap lands past the end of the short name, so the cursor goes after it; then delete it all.
        nameField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let existing = (nameField.value as? String) ?? ""
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        nameField.typeText("Robin Diaz")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["Robin Diaz"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSignOutReturnsToSignIn() {
        let app = launchApp()
        openSettings(in: app)

        app.buttons["Sign Out"].tap()

        XCTAssertTrue(element("signInWithApple", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testDeleteAccountAfterConfirmingReturnsToSignIn() {
        let app = launchApp()
        openSettings(in: app)

        app.buttons["Delete Account"].tap()
        let confirm = app.sheets.buttons["Delete Account"].exists
            ? app.sheets.buttons["Delete Account"]
            : app.buttons.matching(identifier: "Delete Account").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(element("signInWithApple", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testLocationPrimerAppearsOnceBeforeMap() {
        let app = launchApp(locationAuthorization: "notDetermined")
        XCTAssertTrue(app.staticTexts["Show Your Location"].waitForExistence(timeout: 10))

        app.buttons["Not Now"].tap()

        XCTAssertTrue(element("friendRow.798237498DFBRE34", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Allow"].exists, "The map offers permission again from its banner")
    }
}
