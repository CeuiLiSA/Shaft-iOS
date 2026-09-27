import XCTest
import UIKit
@testable import Shaft_iOS

/// Pure-logic checks for the 2026-09 Android sync (TTS text, following-mirror
/// paging, pinned combos, APCA, HSV).
final class AndroidSyncPortTests: XCTestCase {

    // MARK: NovelTtsText

    func testSplitKeepsSourceOffsetsAndSentenceBoundaries() {
        // A sentence boundary is only used when it falls in the back half of the
        // window; otherwise the window is cut hard (upstream NovelTtsText.split).
        let text = "第一句话好。第二句。第三"
        let segments = NovelTtsText.split(text, maxChars: 8)
        XCTAssertEqual(segments.map(\.text), ["第一句话好。", "第二句。第三"])
        XCTAssertEqual(NovelTtsText.split("第一句。第二句很长很长", maxChars: 8).map(\.text), ["第一句。第二句很", "长很长"])
        let ns = text as NSString
        for s in segments {
            XCTAssertEqual(ns.substring(with: NSRange(location: s.sourceStart, length: s.sourceEnd - s.sourceStart)), s.text)
        }
    }

    func testSplitNeverCutsASurrogatePair() {
        let text = String(repeating: "a", count: 3) + "😀" + "bbbb"
        let segments = NovelTtsText.split(text, maxChars: 4)
        XCTAssertFalse(segments.contains { $0.text.unicodeScalars.contains { $0.value == 0xFFFD } })
        XCTAssertEqual(segments.map(\.text).joined(), text)
    }

    func testDetectsJapaneseByKana() {
        XCTAssertEqual(NovelTtsText.detectLanguage("こんにちは世界"), "ja-JP")
        XCTAssertNil(NovelTtsText.detectLanguage("你好世界"))
        XCTAssertEqual(NovelTtsText.maxChars(forLanguage: "ja-JP"), NovelTtsText.japaneseMaxChars)
    }

    func testSegmentsStartMidParagraph() {
        let tokens: [ContentToken] = [
            .chapter(sourceStart: 0, sourceEnd: 5, title: "第一章"),
            .paragraph(sourceStart: 6, sourceEnd: 16, text: "0123456789", textSourceStart: 6, inlineSpans: []),
        ]
        let segments = NovelTtsText.segmentsFromTokens(tokens, startCharIndex: 10)
        XCTAssertEqual(segments.map(\.text), ["456789"])
        XCTAssertEqual(segments.first?.sourceStart, 10)
        XCTAssertEqual(NovelTtsText.paragraphStart(tokens, charIndex: 12), 6)
        XCTAssertEqual(NovelTtsText.paragraphStart(tokens, charIndex: 2), 0)
    }

    // MARK: Following mirror paging

    func testOverlapRewindsOffsetButNeverBackToCurrentPage() {
        let next = "https://app-api.pixiv.net/v1/user/following?user_id=1&restrict=public&offset=30"
        XCTAssertEqual(overlapNextUrl(requested: nil, next: next, overlap: 5),
                       "https://app-api.pixiv.net/v1/user/following?user_id=1&restrict=public&offset=25")
        let page2 = "https://app-api.pixiv.net/v1/user/following?user_id=1&restrict=public&offset=28"
        // Rewinding 5 from 30 would land before the current page (28) → clamp to 29.
        XCTAssertEqual(overlapNextUrl(requested: page2, next: next, overlap: 5),
                       "https://app-api.pixiv.net/v1/user/following?user_id=1&restrict=public&offset=29")
        XCTAssertEqual(overlapNextUrl(requested: nil, next: "https://x/y?max_bookmark_id=9", overlap: 5), "https://x/y?max_bookmark_id=9")
        XCTAssertNil(overlapNextUrl(requested: nil, next: nil, overlap: 5))
    }

    // MARK: Pinned combos

    func testSearchTermsCombinationIdentity() {
        XCTAssertTrue(SearchTerms.same(["原神", "胡桃"], ["胡桃", "原神"]))
        XCTAssertFalse(SearchTerms.same(["a", "OR", "b"], ["b", "OR", "a"]))
        XCTAssertEqual(SearchTerms.split("  原神   胡桃 "), ["原神", "胡桃"])
        XCTAssertEqual(SearchTerms.displayName(["原神", "胡桃"]), "原神 + 胡桃")
    }

    // MARK: Colour

    func testApcaReferenceValues() {
        XCTAssertEqual(ApcaContrast.lc(text: .black, background: .white), 106, accuracy: 1)
        XCTAssertEqual(ApcaContrast.lc(text: .white, background: .black), -107.9, accuracy: 1)
    }

    func testTagLegibilityZeroBoostIsUnchangedAndFullBoostReachesBodyLine() {
        let base = TagLegibility.originalTextUIColor(isDark: true, boost: 0)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertEqual(base.rgb24, UIColor(Theme.v3TagText).resolvedColor(with: traits).rgb24)
        let boosted = TagLegibility.originalTextUIColor(isDark: true, boost: 1)
        let bg = TagLegibility.composite(UIColor(Theme.brand), alpha: 0.2, over: UIColor(Theme.v3CardFill).resolvedColor(with: traits))
        XCTAssertGreaterThanOrEqual(abs(ApcaContrast.lc(text: boosted, background: bg)), 74.5)
    }

    func testHsvRoundTripAndHexNormalize() {
        for rgb: UInt32 in [0xFF0000, 0x10B7F5, 0x333333, 0xFFFFFF, 0x000000] {
            XCTAssertEqual(HSV(rgb: rgb).rgb, rgb)
        }
        XCTAssertEqual(HSV.normalize("#abc"), "#AABBCC")
        XCTAssertNil(HSV.normalize("#12345"))
        XCTAssertEqual(HSV.parse("10b7f5"), 0x10B7F5)
    }

    // MARK: Tablet columns

    func testAdaptiveColumnsNeverFewerThanTheSetting() {
        XCTAssertGreaterThanOrEqual(AdaptiveStaggerColumns.columns(contentWidth: 300, base: 3), 3)
    }
}
