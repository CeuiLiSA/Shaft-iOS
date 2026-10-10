import XCTest
import SwiftUI
@testable import Shaft_iOS

@MainActor final class OctoberRenderTests: XCTestCase {
    func testPrivacyShieldCoversPresentedSheetsAndFullScreenViewsWithoutDismissingThem() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let language = OnboardingStore()
        for style in [UIModalPresentationStyle.pageSheet, .fullScreen] {
            let suite = "october-shield-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let lock = AppLockController(defaults: defaults, authenticationOverride: { _ in true })
            await lock.setEnabled(true, reason: "test")
            let host = UIHostingController(rootView: Color.red.ignoresSafeArea().appLockPresentation(controller: lock).environment(language))
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .normal + 1
            window.rootViewController = host
            window.isHidden = false
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let modal = UIViewController()
            modal.view.backgroundColor = .green
            modal.modalPresentationStyle = style
            defer { window.isHidden = true; window.rootViewController = nil }
            await withCheckedContinuation { continuation in
                host.present(modal, animated: false) { continuation.resume() }
            }
            let before = try centerPixel(of: window)
            XCTAssertGreaterThan(before.green, 0.8)
            let previousKeyWindow = scene.keyWindow
            let previousAccessibilityHidden = window.accessibilityElementsHidden
            lock.update(.inactive)
            try await Task.sleep(for: .milliseconds(100))
            let front = try XCTUnwrap(scene.windows.filter { !$0.isHidden }.max { $0.windowLevel < $1.windowLevel })
            XCTAssertFalse(front === window, "The root overlay must not leave the modal as the frontmost surface (\(style.rawValue))")
            let covered = try centerPixel(of: front)
            XCTAssertLessThan(abs(covered.green - covered.red), 0.15, "The privacy surface must cover the green modal (\(style.rawValue))")
            XCTAssertTrue(front.hitTest(CGPoint(x: front.bounds.midX, y: front.bounds.midY), with: nil)?.window === front)
            XCTAssertTrue(front.isKeyWindow, "Keyboard focus must also remain behind the lock")
            XCTAssertTrue(window.accessibilityElementsHidden, "VoiceOver must not reach the covered modal")
            XCTAssertTrue(host.presentedViewController === modal)
            lock.update(.active)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(host.presentedViewController === modal, "The user's reader/sheet state must survive unlocking")
            let restored = try centerPixel(of: window)
            XCTAssertGreaterThan(restored.green, 0.8)
            XCTAssertTrue(scene.keyWindow === previousKeyWindow)
            XCTAssertEqual(window.accessibilityElementsHidden, previousAccessibilityHidden)
            lock.update(.background); lock.update(.active)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(lock.isLocked)
            let lockedWindow = try XCTUnwrap(scene.windows.filter { !$0.isHidden }.max { $0.windowLevel < $1.windowLevel })
            XCTAssertFalse(lockedWindow === window, "Returning from background must cover the existing presentation")
            await lock.unlock(reason: "test")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(lock.isLocked)
            XCTAssertTrue(host.presentedViewController === modal)
            XCTAssertTrue(lockedWindow.isHidden)
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(lock.privacyShield, "Other active scenes need not put the whole app behind a shield")
            let inactiveWindow = try XCTUnwrap(scene.windows.filter { !$0.isHidden }.max { $0.windowLevel < $1.windowLevel })
            XCTAssertFalse(inactiveWindow === window, "This scene must still cover its own modal while inactive")
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(inactiveWindow.isHidden)
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
        }
    }

    private func centerPixel(of window: UIWindow) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: -CGFloat(cg.width / 2), y: -CGFloat(cg.height / 2))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }

    func testNewScreensInBothThemesNarrowLongTextAndTablet() async throws {
        AppFonts.register()
        let language = OnboardingStore(); language.chosenTag = "zh-Hans"
        for dark in [false, true] {
            try await capture(IllustListLayoutPicker().environment(language), width: 390, name: "layouts-390-\(dark ? "dark" : "light")", dark: dark)
            try await capture(AppLockScreen().environment(language), width: 320, name: "lock-320-\(dark ? "dark" : "light")", dark: dark)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("preferences.json")
            let preferences = WebDAVPreferences(file: file, secrets: OctoberMemorySecrets())
            try await capture(NavigationStack { WebDAVSettingsView(preferences: preferences) }.environment(language),
                              width: 390, name: "webdav-390-\(dark ? "dark" : "light")", dark: dark)
        }
        language.chosenTag = "ru"
        try await capture(IllustListLayoutPicker().environment(language).environment(\.dynamicTypeSize, .accessibility3),
                          width: 320, name: "layouts-320-russian-large", dark: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("preferences.json")
        let preferences = WebDAVPreferences(file: file, secrets: OctoberMemorySecrets())
        for bottom in [false, true] {
            try await capture(NavigationStack { WebDAVSettingsView(preferences: preferences) }.environment(language).environment(\.dynamicTypeSize, .accessibility3),
                              width: 320, name: "webdav-320-russian-large-\(bottom ? "bottom" : "top")", dark: true, scrollBottom: bottom)
        }
        try await capture(AIExemptAuthorsView().environment(language).environment(\.dynamicTypeSize, .accessibility3),
                          width: 320, name: "ai-exempt-320-russian-large", dark: true)
        let stored = AppSettingsStore.shared
        let ids = stored.aiBlockExemptAuthorIds, disabled = stored.aiBlockExemptDisabledIds
        stored.aiBlockExemptAuthorIds = [123456789123456789, Int64.max]; stored.aiBlockExemptDisabledIds = [Int64.max]
        try await capture(AIExemptAuthorsView().environment(language).environment(\.dynamicTypeSize, .accessibility3),
                          width: 320, name: "ai-exempt-states-320-russian-large", dark: true, scrollBottom: true)
        stored.aiBlockExemptAuthorIds = ids; stored.aiBlockExemptDisabledIds = disabled
        try await capture(AppLockScreen().environment(language).environment(\.dynamicTypeSize, .accessibility3),
                          width: 320, name: "lock-320-russian-large", dark: true)
        try await capture(IllustListLayoutPicker().environment(language), width: 768, name: "layouts-tablet", dark: false)
        let settings = AppSettingsStore.shared
        let saved = settings.illustListLayout
        defer { settings.illustListLayout = saved }
        for layout in IllustListLayout.allCases {
            settings.illustListLayout = layout.rawValue
            try await capture(ScrollView { WaterfallSkeleton(columns: 2) }.background(Theme.v3Bg), width: 320,
                              name: "skeleton-\(layout)-320", dark: false)
        }
    }

    private func capture<V: View>(_ content: V, width: CGFloat, name: String, dark: Bool, scrollBottom: Bool = false) async throws {
        let height: CGFloat = 844
        let host = UIHostingController(rootView: content.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        if scrollBottom, let scroll = largestScroll(in: host.view) {
            // Form estimates off-screen row heights; materialize them before the final capture.
            for _ in 0..<5 {
                scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
            }
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, width)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("OctoberPortScreenshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent(name + ".png"))
    }
    private func largestScroll(in view: UIView) -> UIScrollView? {
        var children = view.subviews.compactMap { largestScroll(in: $0) }
        if let scroll = view as? UIScrollView { children.append(scroll) }
        return children.max { $0.contentSize.height < $1.contentSize.height }
    }

}
