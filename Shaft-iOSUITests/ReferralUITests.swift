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

    func testClipboardPromptDeduplicationAndExplicitInviteBinding() {
        app.launchArguments = ["--referral-preview", "--referral-clipboard=ABCD2345", "--referral-reset-prompts"]
        app.launch()
        let code = app.textFields["邀请码"]
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        XCTAssertEqual(code.value as? String, "ABCD2345")
        app.buttons["关闭"].tap()
        launch("--referral-clipboard=ABCD2345")
        XCTAssertFalse(code.exists)
        app.launchArguments = ["--referral-preview", "--referral-code=ABCD2345"]
        app.launch()
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        app.buttons["绑定邀请人"].tap()
        XCTAssertTrue(app.staticTexts["接受邀请成功"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["你已绑定邀请人（UID 99）。"].exists)
        app.buttons["知道了"].tap()
        for _ in 0..<8 { app.swipeUp(velocity: .fast) }
        XCTAssertFalse(app.buttons["我被邀请了"].exists)
        XCTAssertTrue(app.staticTexts["你已绑定邀请人（UID 99）。"].exists)
    }

    func testSubmissionCompletesAndTaskBecomesPending() {
        launch("--referral-scenario=rejected")
        findButton("补充内容：发布 App 推荐帖").tap()
        findButton("提交内容链接").tap()
        let url = app.textFields["内容链接"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.typeText("https://example.com/referral-review")
        let description = app.textFields["内容说明"]
        description.tap(); description.typeText("Original App review with download instructions and reward disclosure.")
        findButton("内容为本人原创，已附 App 下载入口，并注明参与活动可获体验卡。").tap()
        findButton("提交审核").tap()
        XCTAssertTrue(app.staticTexts["已提交"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["知道了"].tap()
        XCTAssertTrue(findButton("查看审核：发布 App 推荐帖").exists)
    }
}
