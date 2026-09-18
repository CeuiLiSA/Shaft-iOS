import XCTest

final class DiscoverSocialUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ args: String...) {
        app.launchArguments = ["--discover-social-preview"] + args
        app.launch()
        XCTAssertTrue(app.buttons["discover-chat-entry"].waitForExistence(timeout: 15))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func reach(_ identifier: String) -> XCUIElement {
        let element = app.buttons[identifier]
        for _ in 0..<10 {
            if element.exists && element.isHittable { return element }
            app.swipeUp(velocity: .slow)
        }
        return element
    }
    func testEntriesOpenTheirActualRoutesAndCanReturn() {
        launch()
        app.buttons["discover-chat-entry"].tap()
        XCTAssertTrue(app.staticTexts["聊天室"].waitForExistence(timeout: 5))
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["discover-community-entry"].waitForExistence(timeout: 5))
        app.buttons["discover-community-entry"].tap()
        XCTAssertTrue(app.buttons["plaza-compose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plaza-filter-all"].exists)
        app.buttons["plaza-back"].tap()
        XCTAssertTrue(app.buttons["discover-chat-entry"].waitForExistence(timeout: 5))
    }
    func testDefaultLightDarkAndAndroidThemeScreenshots() {
        launch(); capture("social-phone-light")
        XCTAssertTrue(app.buttons["discover-community-entry"].isHittable)
        launch("--social-dark"); capture("social-phone-dark")
        XCTAssertTrue(app.buttons["discover-community-entry"].isHittable)
        launch("--social-accent=FE83A2"); capture("social-phone-pink")
    }
    func testNarrowLayoutKeepsBothEntryActionsReachable() {
        launch("--social-width=320")
        capture("social-320-light")
        XCTAssertTrue(reach("discover-chat-entry").isHittable)
        XCTAssertTrue(reach("discover-community-entry").isHittable)
        app.buttons["discover-community-entry"].tap()
        XCTAssertTrue(app.buttons["plaza-compose"].waitForExistence(timeout: 5))
    }
    func testLargeRussianTextRemainsScrollableAndNavigable() {
        launch("--social-width=320", "--social-large", "--social-language=ru")
        capture("social-320-russian-large-top")
        let community = reach("discover-community-entry")
        XCTAssertTrue(community.isHittable)
        app.swipeUp(velocity: .slow)
        XCTAssertLessThanOrEqual(community.frame.maxY, app.frame.maxY)
        capture("social-320-russian-large-bottom")
        // Exercise the bottom action area after scrolling, not just the first
        // visible part of the large card.
        community.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.95)).tap()
        XCTAssertTrue(app.buttons["plaza-compose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plaza-filter-all"].exists)
    }
}
