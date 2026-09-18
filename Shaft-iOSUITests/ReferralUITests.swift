import XCTest

final class ReferralUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ arguments: String...) {
        app.launchArguments = ["--referral-preview"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["referral-theme"].waitForExistence(timeout: 15))
    }
    private func capture(_ name: String) {
        // Capture the settled 200ms sheet transition, never an intermediate frame.
        Thread.sleep(forTimeInterval: 0.4)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func findButton(_ label: String) -> XCUIElement {
        let button = app.buttons[label]
        for _ in 0..<12 {
            if button.exists && button.isHittable { return button }
            app.swipeUp(velocity: .slow)
        }
        return button
    }
    func testLightDarkNarrowAndLargeFontScreenshots() {
        launch(); capture("phone-light-top")
        app.swipeUp(velocity: .slow); capture("phone-light-wallet")
        app.swipeUp(velocity: .slow); capture("phone-light-tasks")
        launch("--referral-dark"); capture("phone-dark-top")
        launch("--referral-width=320"); capture("phone-320-top")
        launch("--referral-width=320", "--referral-large"); capture("phone-320-large-top")
        let rules = app.buttons["活动规则"]
        XCTAssertTrue(rules.isHittable)
        rules.tap(); capture("phone-large-rules")
        XCTAssertTrue(app.buttons["关闭"].isHittable)
    }
    func testInviteCopyAndRules() {
        launch()
        app.buttons["邀请好友"].tap()
        XCTAssertTrue(app.staticTexts["K7M2QX4P"].waitForExistence(timeout: 5))
        capture("invite-sheet")
        app.buttons["复制邀请链接"].tap()
        XCTAssertTrue(app.staticTexts["文案已复制"].waitForExistence(timeout: 3))
        app.buttons["关闭"].tap()
        app.buttons["活动规则"].tap()
        capture("rules-sheet")
        XCTAssertTrue(app.buttons["关闭"].exists)
    }
    func testClaimScrollsToExistingWalletAndActivates() {
        launch()
        findButton("领取奖励：邀请首位好友").tap()
        XCTAssertTrue(app.buttons["领取体验卡"].waitForExistence(timeout: 5))
        capture("claim-sheet")
        app.buttons["领取体验卡"].tap()
        XCTAssertTrue(app.staticTexts["已存入卡包"].waitForExistence(timeout: 5))
        app.buttons["查看卡包"].tap()
        XCTAssertTrue(app.buttons["激活 7 天 PRO"].waitForExistence(timeout: 5))
        capture("claimed-wallet")
        app.buttons["激活 7 天 PRO"].tap()
        capture("activate-sheet")
        app.buttons["确认激活"].tap()
        XCTAssertTrue(app.staticTexts["已激活"].waitForExistence(timeout: 5))
        app.buttons["知道了"].tap()
        XCTAssertFalse(app.buttons["激活 7 天 PRO"].exists)
    }
    func testClosedCampaignAndSubmissionValidation() {
        launch("--referral-scenario=closed-wallet", "--referral-dark")
        findButton("激活 7 天 PRO").tap()
        XCTAssertTrue(app.buttons["确认激活"].waitForExistence(timeout: 5))
        capture("closed-campaign-activate")
        launch("--referral-scenario=rejected")
        findButton("补充内容：发布 App 推荐帖").tap()
        XCTAssertTrue(app.staticTexts["请补充可公开访问的 App 下载入口，并在说明中注明活动奖励关系。"].waitForExistence(timeout: 5))
        findButton("提交内容链接").tap()
        capture("submission-form")
        findButton("提交审核").tap()
        XCTAssertTrue(app.staticTexts["referral-action-error"].waitForExistence(timeout: 5))
    }
    func testErrorAndLongTranslation() {
        launch("--referral-scenario=error"); capture("error-state")
        XCTAssertTrue(app.buttons["重试"].isHittable)
        launch("--referral-language=ru", "--referral-width=320")
        capture("russian-320-top")
        app.swipeUp(velocity: .slow); capture("russian-320-wallet")
    }
}
