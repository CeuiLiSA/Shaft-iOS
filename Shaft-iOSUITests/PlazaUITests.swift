import XCTest

final class PlazaUITests: XCTestCase {
    func testDiscoverOpensPlazaAndDraftCanBeEditedAndDiscarded() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--discover-social-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["discover-community-entry"].waitForExistence(timeout: 15))
        app.buttons["discover-community-entry"].tap()
        XCTAssertTrue(app.buttons["plaza-compose"].waitForExistence(timeout: 10))
        app.buttons["plaza-filter-mine"].tap()
        app.buttons["plaza-filter-all"].tap()
        app.buttons["plaza-compose"].tap()
        let title = app.textFields["plaza-title-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["plaza-publish"].isEnabled)
        title.tap(); title.typeText("Plaza UI draft")
        let body = app.textViews["plaza-body-input"]
        XCTAssertTrue(body.exists)
        body.tap(); body.typeText("Kept locally, never published.")
        XCTAssertTrue(app.buttons["plaza-publish"].isEnabled)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "plaza-draft-interaction"; image.lifetime = .keepAlways; add(image)
        app.buttons["plaza-compose-back"].tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertEqual(body.value as? String, "Kept locally, never published.")
        app.buttons["plaza-compose-back"].tap()
        app.buttons["放弃"].tap()
        XCTAssertTrue(app.buttons["plaza-compose"].waitForExistence(timeout: 5))
        app.buttons["plaza-back"].tap()
        XCTAssertTrue(app.buttons["discover-community-entry"].waitForExistence(timeout: 5))
    }
}
