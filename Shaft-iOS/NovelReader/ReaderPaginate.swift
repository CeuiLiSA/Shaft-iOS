import UIKit

// 1:1 port of upstream TextMeasurer + Paginator. The measurer runs the same
// TextKit configuration the rendering ReaderTextBlockView uses (fixed line
// height, zero fragment padding, greedy word wrapping, no hyphenation), so
// every line break and line height computed here is what the on-screen text
// view reproduces — slicing a paragraph by measured line ranges is exact.

// MARK: - TextMeasurer

struct MeasuredLine {
    /// UTF-16 char range into the measured paragraph text.
    let range: NSRange
    let top: CGFloat
    let bottom: CGFloat
}

enum ReaderTextMeasurer {
    /// Measure a body paragraph at `width`, returning per-line char ranges +
    /// vertical extents. First-line indent applied like upstream
    /// `withFirstLineIndent` so wrap points match the rendered slice.
    static func measureParagraph(_ text: String, style: ReaderTypeStyle, width: CGFloat) -> [MeasuredLine] {
        measure(NSAttributedString(string: text, attributes: style.bodyAttributes(indentFirstLine: true)), width: width)
    }

    /// Chapter headings use a lightweight centred layout at 1.15 spacing.
    static func measureChapter(_ title: String, style: ReaderTypeStyle, width: CGFloat) -> CGFloat {
        let text = title.isEmpty ? "  " : title
        let lines = measure(NSAttributedString(string: text, attributes: style.chapterAttributes()), width: width)
        return lines.last?.bottom ?? style.chapterLineHeight
    }

    static func measure(_ attributed: NSAttributedString, width: CGFloat) -> [MeasuredLine] {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var lines: [MeasuredLine] = []
        var glyphIndex = 0
        let glyphCount = manager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var effective = NSRange(location: 0, length: 0)
            let rect = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effective)
            let charRange = manager.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
            lines.append(MeasuredLine(range: charRange, top: rect.minY, bottom: rect.maxY))
            glyphIndex = NSMaxRange(effective)
        }
        return lines
    }
}

// MARK: - Paginator

/// Flows tokens into concrete pages. Direct port of upstream `Paginator.kt`:
/// images get full pages, chapters force a break and emit a centred title,
/// paragraphs are sliced by measured line ranges, BlankLines become
/// max(paragraphSpacing, fontHeight) spaces, jumps are fixed-height buttons.
struct ReaderPaginator {
    let tokens: [ContentToken]
    let geometry: PageGeometry
    let style: ReaderTypeStyle
    let imageUrlResolver: (ContentToken) -> String?

    private final class State {
        var pages: [ReaderPage] = []
        var currentElements: [PageElement] = []
        var currentY: CGFloat = 0
        var currentCharStart = 0
        var currentCharEnd = 0
        var trackedStartForPage = false
        var currentChapterTitle: String?
    }

    func paginate() -> [ReaderPage] {
        guard !tokens.isEmpty, geometry.contentWidth > 0, geometry.contentHeight > 0 else { return [] }
        let st = State()
        st.currentY = geometry.paddingTop
        for token in tokens {
            process(token, st)
        }
        finishPage(st)
        return st.pages
    }

    private func process(_ token: ContentToken, _ st: State) {
        switch token {
        case .pageBreak(_, let end):
            finishPage(st)
            st.currentCharStart = end
            st.trackedStartForPage = false

        case .uploadedImage(let start, let end, let imageId):
            finishPage(st)
            emitImagePage(st, charStart: start, charEnd: end, element: PageElement.Image(
                top: geometry.paddingTop,
                bottom: geometry.height - geometry.paddingBottom,
                absoluteCharStart: start,
                absoluteCharEnd: end,
                imageType: .uploadedImage,
                resourceId: imageId,
                pageIndexInIllust: 0,
                imageUrl: imageUrlResolver(token)
            ))

        case .pixivImage(let start, let end, let illustId, let pageIndex):
            finishPage(st)
            emitImagePage(st, charStart: start, charEnd: end, element: PageElement.Image(
                top: geometry.paddingTop,
                bottom: geometry.height - geometry.paddingBottom,
                absoluteCharStart: start,
                absoluteCharEnd: end,
                imageType: .pixivImage,
                resourceId: illustId,
                pageIndexInIllust: pageIndex,
                imageUrl: imageUrlResolver(token)
            ))

        case .chapter(let start, let end, let title):
            finishPage(st)
            st.currentChapterTitle = title
            emitChapterHeading(st, sourceStart: start, sourceEnd: end, title: title)

        case .paragraph(let start, _, let text, let textSourceStart, _):
            emitParagraph(st, paragraphIndex: start, text: text, textSourceStart: textSourceStart)

        case .blankLine(let start, let end):
            if !st.currentElements.isEmpty {
                let gap = max(style.paragraphSpacing, style.fontHeight)
                st.currentElements.append(.space(PageElement.Space(
                    top: st.currentY, bottom: st.currentY + gap,
                    absoluteCharStart: start, absoluteCharEnd: end
                )))
                st.currentY += gap
                st.currentCharEnd = end
            }

        case .jump(let start, let end, let target):
            emitJump(st, sourceStart: start, sourceEnd: end, target: target)
        }
    }

    private func emitJump(_ st: State, sourceStart: Int, sourceEnd: Int, target: Int) {
        // Fixed-height row scaled by font size, padded by paragraphSpacing.
        let buttonHeight = style.bodyFont.pointSize * 2.4
        let gap = style.paragraphSpacing
        let totalHeight = buttonHeight + gap * 2
        let remaining = (geometry.height - geometry.paddingBottom) - st.currentY
        if remaining < totalHeight, !st.currentElements.isEmpty {
            finishPage(st)
        }
        st.currentY += gap
        st.currentElements.append(.jump(PageElement.Jump(
            top: st.currentY, bottom: st.currentY + buttonHeight,
            absoluteCharStart: sourceStart, absoluteCharEnd: sourceEnd,
            target: target
        )))
        ensureStartTracked(st, sourceStart)
        st.currentY += buttonHeight + gap
        st.currentCharEnd = sourceEnd
    }

    private func emitImagePage(_ st: State, charStart: Int, charEnd: Int, element: PageElement.Image) {
        st.pages.append(ReaderPage(
            index: st.pages.count,
            elements: [.image(element)],
            charStart: charStart,
            charEnd: charEnd,
            chapterTitle: st.currentChapterTitle
        ))
        st.currentCharStart = charEnd
        st.trackedStartForPage = false
    }

    private func emitChapterHeading(_ st: State, sourceStart: Int, sourceEnd: Int, title: String) {
        let width = geometry.contentWidth
        guard width > 0 else { return }
        st.currentY += style.chapterTopGap
        let height = ReaderTextMeasurer.measureChapter(title, style: style, width: width)
        // If the chapter + at least one text line can't fit, push to next page.
        let minimumRoomNeeded = height + style.bodyFont.pointSize + style.chapterBottomGap
        let remaining = (geometry.height - geometry.paddingBottom) - st.currentY
        if remaining < minimumRoomNeeded, !st.currentElements.isEmpty {
            finishPage(st)
            st.currentY += style.chapterTopGap
        }
        st.currentElements.append(.chapter(PageElement.Chapter(
            top: st.currentY, bottom: st.currentY + height,
            absoluteCharStart: sourceStart, absoluteCharEnd: sourceEnd,
            title: title
        )))
        ensureStartTracked(st, sourceStart)
        st.currentY += height + style.chapterBottomGap
        st.currentCharEnd = sourceEnd
    }

    private func emitParagraph(_ st: State, paragraphIndex: Int, text: String, textSourceStart: Int) {
        let width = geometry.contentWidth
        guard width > 0 else { return }
        let lines = ReaderTextMeasurer.measureParagraph(text, style: style, width: width)
        let total = lines.count
        guard total > 0 else { return }
        let ns = text as NSString

        var cursor = 0
        while cursor < total {
            let remainingHeight = (geometry.height - geometry.paddingBottom) - st.currentY
            if remainingHeight <= 0 {
                finishPage(st)
                continue
            }
            let startTop = lines[cursor].top
            // Does even the first line fit? If not, flush and retry on a fresh
            // page; the empty-page guard prevents an infinite loop when a
            // single line is taller than the page.
            let firstLineHeight = lines[cursor].bottom - startTop
            if firstLineHeight > remainingHeight, !st.currentElements.isEmpty {
                finishPage(st)
                continue
            }
            var linesFit = 0
            var pxUsed: CGFloat = 0
            for i in cursor..<total {
                let pxIfIncluded = lines[i].bottom - startTop
                if pxIfIncluded > remainingHeight, linesFit > 0 { break }
                linesFit = i - cursor + 1
                pxUsed = pxIfIncluded
                if pxIfIncluded > remainingHeight {
                    // Single line that won't fit even on a blank page — emit
                    // anyway so we don't drop content.
                    break
                }
            }
            if linesFit == 0 {
                finishPage(st)
                continue
            }

            let startChar = min(max(lines[cursor].range.location, 0), ns.length)
            let lastRange = lines[cursor + linesFit - 1].range
            let endChar = min(max(lastRange.location + lastRange.length, 0), ns.length)
            let absoluteStart = textSourceStart + startChar
            let absoluteEnd = textSourceStart + endChar
            let sliceText = ns.substring(with: NSRange(location: startChar, length: endChar - startChar))

            st.currentElements.append(.text(PageElement.Text(
                top: st.currentY, bottom: st.currentY + pxUsed,
                absoluteCharStart: absoluteStart, absoluteCharEnd: absoluteEnd,
                text: sliceText,
                paragraphIndex: paragraphIndex,
                isFirstLineOfParagraph: cursor == 0,
                isLastLineOfParagraph: (cursor + linesFit) == total,
                lineCount: linesFit
            )))
            ensureStartTracked(st, absoluteStart)
            st.currentY += pxUsed
            st.currentCharEnd = absoluteEnd
            cursor += linesFit

            if cursor < total {
                finishPage(st)
            } else {
                st.currentY += style.paragraphSpacing
            }
        }
    }

    private func ensureStartTracked(_ st: State, _ start: Int) {
        if !st.trackedStartForPage {
            st.currentCharStart = start
            st.trackedStartForPage = true
        }
    }

    private func finishPage(_ st: State) {
        if st.currentElements.isEmpty {
            st.currentY = geometry.paddingTop
            st.trackedStartForPage = false
            return
        }
        st.pages.append(ReaderPage(
            index: st.pages.count,
            elements: st.currentElements,
            charStart: st.currentCharStart,
            charEnd: st.currentCharEnd,
            chapterTitle: st.currentChapterTitle
        ))
        st.currentElements.removeAll()
        st.currentY = geometry.paddingTop
        st.currentCharStart = st.currentCharEnd
        st.trackedStartForPage = false
    }
}
