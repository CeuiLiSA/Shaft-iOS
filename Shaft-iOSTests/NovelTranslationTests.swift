import XCTest
@testable import Shaft_iOS

/// issue #864：小说全文翻译。Ports upstream `TranslationInserterTest` + `PageAnchorTest`,
/// plus the iOS-side paginator / gtx plumbing they sit on.
@MainActor final class NovelTranslationTests: XCTestCase {

    // MARK: TranslationInserter

    private func paragraphs(_ count: Int, lengthEach: Int = 10) -> [ContentToken] {
        (0..<count).map { i in
            let start = i * (lengthEach + 1)
            return .paragraph(sourceStart: start, sourceEnd: start + lengthEach, text: "段落\(i)",
                              textSourceStart: start, inlineSpans: [])
        }
    }

    private func fields(_ token: ContentToken) -> (start: Int, end: Int, text: String, textStart: Int, role: TranslationRole)? {
        guard case .paragraph(let s, let e, let t, let ts, _, let r) = token else { return nil }
        return (s, e, t, ts, r)
    }

    func testNoTranslationsReturnsOriginalTokensUntouched() {
        let tokens = paragraphs(5)
        let out = TranslationInserter.insert(tokens, translations: [:], role: .interlinear)
        XCTAssertEqual(out.map { fields($0)!.text }, tokens.map { fields($0)!.text })
    }

    func testTranslationFollowsItsOwnParagraphWithZeroWidthSourceOffsets() throws {
        let tokens = paragraphs(3)
        let out = TranslationInserter.insert(tokens, translations: [tokens[1].sourceStart: "译文1"], role: .interlinear)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(fields(out[1])?.text, "段落1")
        let t = try XCTUnwrap(fields(out[2]))
        XCTAssertEqual(t.role, .interlinear)
        XCTAssertEqual(t.text, "译文1")
        XCTAssertEqual(t.start, tokens[1].sourceEnd)
        XCTAssertEqual(t.end, tokens[1].sourceEnd)
        XCTAssertEqual(t.textStart, tokens[1].sourceEnd)
        XCTAssertEqual(fields(out[3])?.text, "段落2")
    }

    func testBlankTranslationsAreSkippedAndAnchorsStayMonotonic() {
        let tokens = paragraphs(4)
        var map: [Int: String] = [:]
        for token in tokens { map[token.sourceStart] = token.sourceStart == tokens[2].sourceStart ? "  " : "译\(fields(token)!.text)" }
        let out = TranslationInserter.insert(tokens, translations: map, role: .interlinear)
        XCTAssertEqual(out.count, 7)
        let anchors = out.map(\.sourceStart)
        XCTAssertEqual(anchors.sorted(), anchors)
    }

    func testReplacementSwapsTheParagraphTextButKeepsItsSourceRange() throws {
        let tokens = paragraphs(3)
        let out = TranslationInserter.insert(tokens, translations: [tokens[1].sourceStart: "译文1"], role: .replacement)
        XCTAssertEqual(out.count, 3)
        let r = try XCTUnwrap(fields(out[1]))
        XCTAssertEqual(r.role, .replacement)
        XCTAssertEqual(r.text, "译文1")
        XCTAssertEqual(r.start, tokens[1].sourceStart)
        XCTAssertEqual(r.end, tokens[1].sourceEnd)
        XCTAssertEqual(r.textStart, fields(tokens[1])!.textStart)
        XCTAssertEqual(fields(out[2])?.text, "段落2")
    }

    // MARK: indexOfPageForAnchor

    private func pages(_ ranges: [(Int, Int)]) -> [ReaderPage] {
        ranges.enumerated().map { i, r in
            ReaderPage(index: i, elements: [], charStart: r.0, charEnd: r.1, chapterTitle: nil)
        }
    }

    func testAnchorOnAPageBoundaryBelongsToThePageThatStartsThere() {
        // 第 0 页以一个跨页段落的前半截收尾（charEnd = 120），第 1 页从它的后半截开始。
        XCTAssertEqual(pages([(0, 120), (120, 260), (261, 400)]).indexOfPageForAnchor(120), 1)
    }

    func testAnchorInsideAPageResolvesToThatPage() {
        let list = pages([(0, 120), (120, 260), (261, 400)])
        XCTAssertEqual(list.indexOfPageForAnchor(0), 0)
        XCTAssertEqual(list.indexOfPageForAnchor(200), 1)
        XCTAssertEqual(list.indexOfPageForAnchor(261), 2)
    }

    func testAnchorAtTheEndOfTheBookFallsBackToTheLastPage() {
        let list = pages([(0, 120), (120, 260)])
        XCTAssertEqual(list.indexOfPageForAnchor(260), 1)
        XCTAssertEqual(list.indexOfPageForAnchor(999), 1)
    }

    func testEmptyPagesResolveToZero() {
        XCTAssertEqual(pages([]).indexOfPageForAnchor(42), 0)
    }

    func testZeroWidthPageIsFoundAgainByItsStart() {
        // 第 1 页零宽度（charStart == charEnd == 120）：停在它上面时锚点 = 120，重排版后必须回到这一页。
        XCTAssertEqual(pages([(0, 120), (120, 120), (130, 260)]).indexOfPageForAnchor(120), 1)
    }

    func testAnchorBetweenPagesThatMatchesNoPageStartUsesTheStrictEndRule() {
        XCTAssertEqual(pages([(0, 120), (120, 120), (130, 260)]).indexOfPageForAnchor(125), 2)
    }

    // MARK: Paginator

    private func paginate(_ tokens: [ContentToken], height: CGFloat = 4000) -> (pages: [ReaderPage], style: ReaderTypeStyle) {
        let style = ReaderTypeStyle.resolve(settings: .shared, theme: .kraft)
        let geometry = PageGeometry(width: 360, height: height, paddingLeft: 20, paddingTop: 24, paddingRight: 20, paddingBottom: 24)
        let pages = ReaderPaginator(tokens: tokens, geometry: geometry, style: style, imageUrlResolver: { _ in nil }).paginate()
        return (pages, style)
    }

    private func textElements(_ pages: [ReaderPage]) -> [PageElement.Text] {
        pages.flatMap(\.elements).compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }

    func testInterlinearSlicesArePinnedToAZeroWidthAnchorAndTightenTheGapAbove() throws {
        let tokens = paragraphs(3)
        let shown = TranslationInserter.insert(tokens, translations: [tokens[1].sourceStart: "Translation of paragraph one"],
                                               role: .interlinear)
        let (pages, style) = paginate(shown)
        let texts = textElements(pages)
        XCTAssertEqual(texts.count, 4)
        let original = texts[1], translation = texts[2], next = texts[3]
        XCTAssertTrue(translation.isInterlinear)
        XCTAssertEqual(translation.absoluteCharStart, tokens[1].sourceEnd)
        XCTAssertEqual(translation.absoluteCharEnd, tokens[1].sourceEnd)
        XCTAssertEqual(translation.top - original.bottom, style.translationGap, accuracy: 0.001)
        XCTAssertEqual(next.top - translation.bottom, style.paragraphSpacing, accuracy: 0.001)
        XCTAssertLessThan(style.translationGap, style.paragraphSpacing)
        XCTAssertEqual(style.translationFont.pointSize, style.bodyFont.pointSize * 0.9, accuracy: 0.001)
    }

    func testReplacementSlicesSplitAcrossPagesMapProportionallyOntoTheSourceRange() throws {
        // 一段原文 0..<100，被一段很长的译文顶替；页很矮，译文必然跨页。
        let source: ContentToken = .paragraph(sourceStart: 0, sourceEnd: 100, text: String(repeating: "原", count: 100),
                                              textSourceStart: 0, inlineSpans: [])
        let shown = TranslationInserter.insert([source], translations: [0: String(repeating: "Translated text. ", count: 60)],
                                               role: .replacement)
        let (pages, _) = paginate(shown, height: 300)
        XCTAssertGreaterThan(pages.count, 1)
        let texts = textElements(pages)
        XCTAssertEqual(texts.first?.absoluteCharStart, 0)
        XCTAssertEqual(texts.last?.absoluteCharEnd, 100)
        for (a, b) in zip(texts, texts.dropFirst()) {
            XCTAssertEqual(a.absoluteCharEnd, b.absoluteCharStart)
            XCTAssertLessThan(b.absoluteCharStart, b.absoluteCharEnd)
        }
        // 续页的页首与前一页的 charEnd 相等，按锚点能落回续页本身。
        for i in 1..<pages.count {
            XCTAssertEqual(pages.indexOfPageForAnchor(pages[i].charStart), i)
        }
    }

    // MARK: Translator plumbing

    func testChunkByCharLimitKeepsEachChunkUnderTheLimit() {
        let inputs = [String(repeating: "a", count: 1500), String(repeating: "b", count: 1500),
                      String(repeating: "c", count: 1500), String(repeating: "d", count: 5000), "e"]
        let ranges = NovelBodyTranslator.chunkByCharLimit(inputs, limit: 4000)
        XCTAssertEqual(ranges.map { [$0.0, $0.1] }, [[0, 2], [2, 3], [3, 4], [4, 5]])
    }

    func testGtxResponseJoinsSentenceSegments() throws {
        let body = #"[[["你好，","こんにちは、",null,null,10],["世界\n第二行","世界\n二行目",null,null,10]],null,"ja"]"#
        XCTAssertEqual(try GoogleGtx.parse(Data(body.utf8)), "你好，世界\n第二行")
    }

    func testAppLanguageMapsToGtxTargetLang() {
        XCTAssertEqual(translateTargetLang(appTag: "zh-Hans"), "zh-CN")
        XCTAssertEqual(translateTargetLang(appTag: "zh-Hant"), "zh-TW")
        XCTAssertEqual(translateTargetLang(appTag: "ja"), "ja")
        XCTAssertEqual(translateTargetLang(appTag: "tr"), "tr")
    }
}
