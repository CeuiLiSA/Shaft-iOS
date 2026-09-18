import XCTest
import SwiftUI
@testable import Shaft_iOS

@MainActor final class StickerRenderTests: XCTestCase {
    private var root: URL!
    private var ready: StickerReady!
    override func setUpWithError() throws {
        AppFonts.register()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-render-\(UUID())")
        ready = try StickerFixtures.install(root: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testPhoneTabletNarrowLargeTextAndStates() async throws {
        for (width, dark, category, tag, size, inline, name) in [
            (390, false, 0, "zh-Hans", DynamicTypeSize.large, false, "picker-390-light"),
            (390, true, 1, "zh-Hans", .large, false, "picker-390-dark"),
            (390, false, 2, "en", .large, false, "picker-animation"),
            (320, true, 2, "ru", .accessibility2, false, "picker-320-large-russian"),
            (768, false, 0, "zh-Hans", .large, false, "picker-tablet"),
            (390, true, 0, "zh-Hans", .large, true, "picker-inline-dark")
        ] {
            let language = OnboardingStore(); language.chosenTag = tag
            let position = StickerPickerPosition(); position.generation = ready.generation; position.category = category
            let view = StickerPicker(inline: inline, primary: PlazaPalette.primary, position: position,
                                     repository: StickerRepository(ready: ready), preparesResources: false, onPick: { _ in })
                .environment(language).environment(\.dynamicTypeSize, size)
            try await capture(view, width: CGFloat(width), height: inline ? 270 : 420, dark: dark, name: name)
        }
        let language = OnboardingStore(); language.chosenTag = "zh-Hans"
        let failed = StickerRepository(ready: ready)
        failed.localFailure(StickerFailure.missingFile, generation: ready.generation)
        try await capture(StickerPicker(repository: failed, preparesResources: false, onPick: { _ in }).environment(language),
                          width: 320, height: 420, dark: true, name: "picker-failed")
        try await capture(StickerPicker(repository: StickerRepository(root: root), preparesResources: false, onPick: { _ in }).environment(language),
                          width: 390, height: 420, dark: false, name: "picker-checking")
        let repository = StickerRepository(ready: ready)
        let messages = VStack(alignment: .leading, spacing: 24) {
            StickerMessageContent(id: ready.items[0][0].id, time: "12:30", repository: repository)
            StickerMessageContent(id: ready.items[2][0].id, time: "12:31", failed: true, repository: repository).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.v3Bg).environment(language)
        try await capture(messages, width: 390, height: 240, dark: false, name: "chat-stickers-light")
        try await capture(messages, width: 390, height: 240, dark: true, name: "chat-stickers-dark")
    }

    func testSelectionContinuousIndicatorAndIndependentScrollRestoration() async throws {
        let language = OnboardingStore(); language.chosenTag = "zh-Hans"
        let position = StickerPickerPosition(), repository = StickerRepository(ready: ready)
        var selected: Sticker?
        let view = StickerPicker(position: position, repository: repository, preparesResources: false) { selected = $0 }.environment(language)
        let (host, window) = makeHost(view, width: 390, height: 420, dark: false)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        let all = descendants(host.view)
        let track = try XCTUnwrap(all.first { $0.accessibilityIdentifier == "sticker-tab-track" })
        let indicator = try XCTUnwrap(all.first { $0.accessibilityIdentifier == "sticker-tab-indicator" })
        XCTAssertEqual(track.bounds.height, 42, accuracy: 0.1)
        XCTAssertEqual(indicator.bounds.height, 36, accuracy: 0.1)
        let grid = try XCTUnwrap(all.first { $0.accessibilityIdentifier == "sticker-grid-customized" } as? UICollectionView)
        let other = try XCTUnwrap(all.first { $0.accessibilityIdentifier == "sticker-grid-static" } as? UICollectionView)
        let pager = try XCTUnwrap(grid.superview as? UIScrollView)
        XCTAssertEqual(grid.visibleCells.first?.bounds.height, 48)
        grid.setContentOffset(CGPoint(x: -12, y: 100), animated: false)
        let initialScroll = grid.contentOffset.y
        let initialIndicator = indicator.frame.minX
        pager.setContentOffset(CGPoint(x: 195, y: 0), animated: false)
        XCTAssertGreaterThan(indicator.frame.minX, initialIndicator)
        pager.setContentOffset(.zero, animated: false)
        XCTAssertEqual(indicator.frame.minX, initialIndicator, accuracy: 0.1)
        let tab = try XCTUnwrap(all.first { $0.accessibilityIdentifier == "sticker-tab-static" } as? UIButton)
        tab.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(position.category, 1)
        XCTAssertEqual(grid.contentOffset.y, initialScroll, accuracy: 0.1)
        other.delegate?.collectionView?(other, didSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertEqual(selected?.id, ready.items[1][0].id)
        let previous = other.contentOffset
        tab.sendActions(for: .touchUpInside)
        XCTAssertEqual(previous, other.contentOffset)
        XCTAssertEqual(tabs(in: all).count, 3)
    }

    private func tabs(in views: [UIView]) -> [UIView] { views.filter { $0 is UIButton && ($0.accessibilityIdentifier?.hasPrefix("sticker-tab-") ?? false) } }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func makeHost<V: View>(_ content: V, width: CGFloat, height: CGFloat, dark: Bool) -> (UIHostingController<AnyView>, UIWindow) {
        let host = UIHostingController(rootView: AnyView(content.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light).ignoresSafeArea()))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(frame: host.view.frame); window.rootViewController = host; window.isHidden = false
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        return (host, window)
    }
    private func capture<V: View>(_ content: V, width: CGFloat, height: CGFloat, dark: Bool, name: String) async throws {
        let (host, window) = makeHost(content, width: width, height: height, dark: dark)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(450))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(image.size, CGSize(width: width, height: height))
    }
}
