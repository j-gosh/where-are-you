//
//  MapScreenUITests.swift
//  where-are-youUITests
//

import XCTest

final class MapScreenUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches against the app's fakes (see `LaunchEnvironment` in the app target).
    @MainActor
    private func launchApp(locationAuthorization: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_FAKE_SERVICES"] = "1"
        app.launchEnvironment["UITEST_RESET_STATE"] = "1"
        if let locationAuthorization {
            app.launchEnvironment["UITEST_LOCATION_AUTH"] = locationAuthorization
        }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func staticText(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func testPeopleListOpensFriendDetail() {
        let app = launchApp()
        let row = element("friendRow.798237498DFBRE34", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        row.tap()

        XCTAssertTrue(app.buttons["Directions"].waitForExistence(timeout: 5))
        // LabeledContent reads as one element: "Address, <value>".
        XCTAssertTrue(staticText(containing: "1 Example Street, San Francisco", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testFriendWithoutLocationSaysSo() {
        let app = launchApp()
        let row = element("friendRow.808080283409JLHSJB", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        row.tap()

        XCTAssertTrue(app.staticTexts["Location not available"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Directions"].exists)
    }

    @MainActor
    func testDeniedLocationShowsSettingsBanner() {
        let app = launchApp(locationAuthorization: "denied")

        XCTAssertTrue(element("locationBanner", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    @MainActor
    func testAuthorizedLocationShowsNoBanner() {
        let app = launchApp()
        XCTAssertTrue(element("friendRow.798237498DFBRE34", in: app).waitForExistence(timeout: 10))

        XCTAssertFalse(element("locationBanner", in: app).exists)
    }
}
