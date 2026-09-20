import XCTest
@testable import Shaft_iOS

final class ImageHostManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "ImageHostManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        hydrate(mode: 0)
    }

    override func tearDown() {
        ImageHostManager.hydrate(defaults: UserDefaults())
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func hydrate(mode: Int, host: String = "") {
        defaults.set(mode, forKey: "st_imageHostMode")
        defaults.set(host, forKey: "st_customImageHost")
        ImageHostManager.hydrate(defaults: defaults)
    }

    func testOfficialModeLeavesBothPixivHostsUnchanged() {
        XCTAssertEqual(ImageHostManager.rewrite("https://i.pximg.net/img/x.jpg"),
                       "https://i.pximg.net/img/x.jpg")
        XCTAssertEqual(ImageHostManager.rewrite("https://s.pximg.net/common/x.png"),
                       "https://s.pximg.net/common/x.png")
    }

    func testMirrorModeMapsImageAndStaticHostsAndHostOnlyURLs() {
        hydrate(mode: ImageHostMode.pixivCat.rawValue)
        XCTAssertEqual(ImageHostManager.rewrite("https://i.pximg.net/img/x.jpg?size=large"),
                       "https://i.pixiv.cat/img/x.jpg?size=large")
        XCTAssertEqual(ImageHostManager.rewrite("https://s.pximg.net/common/x.png"),
                       "https://s.pixiv.cat/common/x.png")
        XCTAssertEqual(ImageHostManager.rewrite("https://i.pximg.net"),
                       "https://i.pixiv.cat")
        XCTAssertEqual(ImageHostManager.rewrite("https://s.pximg.net?probe=1"),
                       "https://s.pixiv.cat?probe=1")
    }

    func testCustomModePreservesProxyPathAndDoesNotTouchUnknownHosts() {
        hydrate(mode: ImageHostMode.custom.rawValue, host: "  https://proxy.example/pixiv///  ")
        XCTAssertEqual(ImageHostManager.customHost, "https://proxy.example/pixiv")
        XCTAssertEqual(ImageHostManager.rewrite("https://i.pximg.net/img/x.jpg"),
                       "https://proxy.example/pixiv/img/x.jpg")
        XCTAssertEqual(ImageHostManager.rewrite("https://example.com/img/x.jpg"),
                       "https://example.com/img/x.jpg")
        XCTAssertTrue(ImageHostManager.requiresStandardClient())
    }

    func testInvalidPersistedModeFallsBackToOfficial() {
        hydrate(mode: 99, host: "https://proxy.example")
        XCTAssertEqual(ImageHostManager.mode, .pixiv)
        XCTAssertFalse(ImageHostManager.requiresStandardClient())
        XCTAssertEqual(ImageHostManager.rewrite("https://i.pximg.net/img/x.jpg"),
                       "https://i.pximg.net/img/x.jpg")
    }
}
