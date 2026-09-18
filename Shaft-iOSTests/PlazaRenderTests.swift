import XCTest
import SwiftUI
@testable import Shaft_iOS

private final class PlazaFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "plaza-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let file = Bundle(for: PlazaRenderTests.self).url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: "png", subdirectory: "PlazaFixtures"),
              let data = try? Data(contentsOf: file) else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class PlazaRenderTests: XCTestCase {
    func testRenderPhoneTabletAndAccessibilityStates() async throws {
        URLProtocol.registerClass(PlazaFixtureProtocol.self)
        defer { URLProtocol.unregisterClass(PlazaFixtureProtocol.self) }
        AppFonts.register()
        let language = OnboardingStore(); language.chosenTag = "zh-Hans"
        let store = PlazaStore(currentUID: { 42 })
        var post = PlazaPost(id: 1, uid: 42, displayName: "Ayaba Onile-Ire", text: "Route Overview\nTotal Distance: ~1,800 km Recommended Duration: 12–14 days", createdAt: 1778371200000,
            likeCount: 0, replyCount: 8, liked: true, title: "New Zealand South Island Road Trip Itinerary",
            reactions: [.init(emoji: "👀", count: 38, selected: true), .init(emoji: "💪", count: 19, selected: false), .init(emoji: "👌", count: 32, selected: false), .init(emoji: "😂", count: 2, selected: false), .init(emoji: "🤔", count: 6, selected: false)],
            commentsPreview: [.init(id: 2, uid: 50, displayName: "Brian", text: "12 days vibe hits different 🚐 No rush and plenty of stops"), .init(id: 3, uid: 51, displayName: "Bojan", text: "Autumn views are chef's kiss 🍂 Saved this route!")])
        post.avatarUrl = "https://plaza-fixture.invalid/imgEllipse2690.png"
        post.images = (0..<9).map { index in
            PlazaImage(mediaId: String(index), width: 960, height: 1200, contentType: "image/png",
                       url: "https://plaza-fixture.invalid/imgGaleryImg\(index == 0 ? "" : String(index)).png", expiresAt: plazaNow() + 600_000)
        }
        store.accept(post)
        for dark in [false, true] {
            for detail in [false, true] {
                let screen = VStack(spacing: 0) {
                    PlazaToolbar(back: {}) {
                        PlazaText(value: detail ? "帖子详情" : "广场", size: 18, color: .white)
                    } trailing: { PlazaText(value: detail ? "更多" : "发帖", size: 14, color: .white).padding(12) }
                    PlazaPostView(post: post, store: store, detail: detail)
                }.background(Theme.v3Bg).environment(language)
                try await capture(screen, width: 390, height: detail ? 1200 : 1060, name: "\(detail ? "detail" : "feed")-390-\(dark ? "dark" : "light")", dark: dark)
            }
        }
        for width in [CGFloat(320), 390, 768] {
            let model = PlazaComposerModel(uid: 42, persistent: false)
            let screen = PlazaComposeView(store: store, model: model, onSent: { _ in }).environment(language)
            try await capture(screen, width: width, height: 844, name: "compose-\(Int(width))-light", dark: false)
        }
        let filled = PlazaComposerModel(uid: 42, persistent: false, draftKey: "render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: filled.directory) }
        for index in 0..<3 {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "imgGaleryImg\(index == 0 ? "" : String(index))", withExtension: "png", subdirectory: "PlazaFixtures"))
            let photo = try PlazaPhotoFiles.importFile(source, directory: filled.directory)
            filled.edit { $0.images.append(photo) }
        }
        filled.edit {
            $0.title = post.title ?? ""
            $0.text = "Route Overview\nTotal Distance: ~1,800 km\nRecommended Duration: 12–14 days\nBest Seasons: Spring & Autumn (Oct–Nov, Mar–Apr)\nTransport: Self-drive (Campervan or SUV)\nRoute Overview\nTotal Distance: ~1,800 km\nRecommended Duration: 12–14 days"
            $0.objectId = 123456; $0.objectType = "illust"
        }
        try await capture(PlazaComposeView(store: store, model: filled, onSent: { _ in }).environment(language),
                          width: 390, height: 1000, name: "compose-filled-390-light", dark: false)
        let service = PlazaTestService()
        await service.setPost(post)
        for dark in [false, true] {
            let feed = PlazaStore(api: service, currentUID: { 42 })
            try await capture(NavigationStack { PlazaView(store: feed) }.environment(language),
                              width: 390, height: 844, name: "timeline-390-\(dark ? "dark" : "light")", dark: dark)
        }
        try await capture(PlazaPostView(post: post, store: store, comment: true).environment(language).background(Theme.v3Bg),
                          width: 390, height: 1000, name: "comment-390-light", dark: false)
        let long = PlazaComposerModel(uid: 42, persistent: false)
        long.edit { $0.title = String(repeating: "很长的标题", count: 20); $0.text = "支持字体放大，失败后保留草稿。" }
        try await capture(PlazaComposeView(store: store, model: long, onSent: { _ in }).environment(language).environment(\.dynamicTypeSize, .accessibility3),
                          width: 320, height: 844, name: "compose-320-large-dark", dark: true)
        try await capture(PlazaStateView(text: "还没有评论，做第一个").environment(language).background(Theme.v3Bg), width: 390, height: 500, name: "empty-light", dark: false)
        try await capture(PlazaStateView(text: "网络连接失败，请重试", error: true, actionTitle: "重试", action: {}).environment(language).background(Theme.v3Bg), width: 390, height: 500, name: "error-dark", dark: true)
    }
    private func capture<V: View>(_ content: V, width: CGFloat, height: CGFloat, name: String, dark: Bool) async throws {
        let host = UIHostingController(rootView: content.frame(width: width, height: height, alignment: .top).environment(\.colorScheme, dark ? .dark : .light).ignoresSafeArea())
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, width)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }
}
