//
//  SharingAndAlertsUITests.swift
//  where-are-youUITests
//

import XCTest

final class SharingAndAlertsUITests: XCTestCase {
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
    private func openOlivia(in app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.waitForExistence(timeout: 10) {
            grabber.swipeUp()
        }
        let row = app.descendants(matching: .any)["friendRow.QW345DVJjdfe"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    /// Scrolls the current list until `element` is on screen.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    /// SwiftUI toggles only flip when the switch itself is tapped.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @MainActor
    func testSharingWithAFriend() {
        let app = launchApp()
        openOlivia(in: app)
        let toggle = app.switches["shareWithFriendToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")

        flip(toggle)

        let isOn = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)
        wait(for: [isOn], timeout: 5)
    }

    @MainActor
    func testAddingALocationAlertListsIt() {
        let app = launchApp()
        openOlivia(in: app)
        let add = app.buttons["addLocationAlert"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        scrollTo(add, in: app)
        add.tap()

        let name = app.textFields["alertPlaceName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Home")
        app.buttons["Add"].tap()

        XCTAssertTrue(app.staticTexts["Arriving at Home"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsShowsSharingAndAlertsOnYou() {
        let app = launchApp()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        XCTAssertTrue(app.switches["shareMyLocationToggle"].waitForExistence(timeout: 5))
        let empty = app.staticTexts["No one has set an alert on you."]
        scrollTo(empty, in: app)
    }
}
