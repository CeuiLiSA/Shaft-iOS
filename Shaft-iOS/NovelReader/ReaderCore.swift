import UIKit

// 1:1 port of Pixiv-Shaft `novel/reader` core models + ContentParser +
// InlineMarkupProcessor + SearchEngine. All character offsets are UTF-16
// units into the raw `WebNovel.text` (matching Java char offsets upstream),
// so progress anchors / bookmarks / annotations stay stable across
// re-paginations and match what the Android app would record.

// MARK: - Inline markup

enum InlineTag: Equatable {
    case link(url: String)
    case ruby(rubyText: String)
}

/// A span of inline markup within a paragraph's display text.
/// `start`/`end` are UTF-16 offsets in the **processed** (stripped) text.
struct InlineSpan: Equatable {
    let start: Int
    let end: Int
    let tag: InlineTag
}

/// `[[jumpuri:display>URL]]` + `[[rb:base>ruby]]` processing — strips the
/// markup and maps spans onto the cleaned display text.
enum InlineMarkupProcessor {
    struct ProcessResult {
        let text: String
        let spans: [InlineSpan]
    }

    private static let jumpUriRegex = try! NSRegularExpression(pattern: #"\[\[jumpuri:([^>]+)>([^\]]+)]]"#)
    private static let rubyRegex = try! NSRegularExpression(pattern: #"\[\[rb:([^>]+)>([^\]]+)]]"#)

    static func process(_ raw: String) -> ProcessResult {
        // Fast path: no `[[` means no inline tags possible.
        guard raw.contains("[[") else { return ProcessResult(text: raw, spans: []) }

        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        struct TagMatch {
            let range: NSRange
            let displayText: String
            let tag: InlineTag
        }
        var matches: [TagMatch] = []
        for m in jumpUriRegex.matches(in: raw, range: full) {
            matches.append(TagMatch(
                range: m.range,
                displayText: ns.substring(with: m.range(at: 1)),
                tag: .link(url: ns.substring(with: m.range(at: 2)))
            ))
        }
        for m in rubyRegex.matches(in: raw, range: full) {
            matches.append(TagMatch(
                range: m.range,
                displayText: ns.substring(with: m.range(at: 1)),
                tag: .ruby(rubyText: ns.substring(with: m.range(at: 2)))
            ))
        }
        if matches.isEmpty { return ProcessResult(text: raw, spans: []) }
        matches.sort { $0.range.location < $1.range.location }

        let sb = NSMutableString(capacity: ns.length)
        var spans: [InlineSpan] = []
        var cursor = 0
        for tm in matches {
            if tm.range.location < cursor { continue } // overlapping match, skip
            sb.append(ns.substring(with: NSRange(location: cursor, length: tm.range.location - cursor)))
            let spanStart = sb.length
            sb.append(tm.displayText)
            spans.append(InlineSpan(start: spanStart, end: sb.length, tag: tm.tag))
            cursor = tm.range.location + tm.range.length
        }
        sb.append(ns.substring(from: cursor))
        return ProcessResult(text: sb as String, spans: spans)
    }
}

// MARK: - Content tokens

enum ContentToken {
    case paragraph(sourceStart: Int, sourceEnd: Int, text: String, textSourceStart: Int, inlineSpans: [InlineSpan])
    case chapter(sourceStart: Int, sourceEnd: Int, title: String)
    case pixivImage(sourceStart: Int, sourceEnd: Int, illustId: Int64, pageIndex: Int)
    case uploadedImage(sourceStart: Int, sourceEnd: Int, imageId: Int64)
    case pageBreak(sourceStart: Int, sourceEnd: Int)
    case blankLine(sourceStart: Int, sourceEnd: Int)
    /// `[jump:N]` — 1-indexed `[newpage]` segment navigation button.
    case jump(sourceStart: Int, sourceEnd: Int, target: Int)

    var sourceStart: Int {
        switch self {
        case .paragraph(let s, _, _, _, _), .chapter(let s, _, _),
             .pixivImage(let s, _, _, _), .uploadedImage(let s, _, _),
             .pageBreak(let s, _), .blankLine(let s, _), .jump(let s, _, _):
            return s
        }
    }

    var sourceEnd: Int {
        switch self {
        case .paragraph(_, let e, _, _, _), .chapter(_, let e, _),
             .pixivImage(_, let e, _, _), .uploadedImage(_, let e, _),
             .pageBreak(_, let e), .blankLine(_, let e), .jump(_, let e, _):
            return e
        }
    }
}

struct ChapterOutlineEntry: Hashable, Identifiable {
    let title: String
    let sourceStart: Int
    var id: Int { sourceStart }
}

// MARK: - Page model

enum PageElement {
    struct Text {
        var top: CGFloat
        var bottom: CGFloat
        var absoluteCharStart: Int
        var absoluteCharEnd: Int
        var text: String
        var paragraphIndex: Int
        var isFirstLineOfParagraph: Bool
        var isLastLineOfParagraph: Bool
        var lineCount: Int
    }

    struct Chapter {
        var top: CGFloat
        var bottom: CGFloat
        var absoluteCharStart: Int
        var absoluteCharEnd: Int
        var title: String
    }

    struct Image {
        enum ImageType: String { case pixivImage, uploadedImage }
        var top: CGFloat
        var bottom: CGFloat
        var absoluteCharStart: Int
        var absoluteCharEnd: Int
        var imageType: ImageType
        var resourceId: Int64
        var pageIndexInIllust: Int
        var imageUrl: String?
    }

    struct Space {
        var top: CGFloat
        var bottom: CGFloat
        var absoluteCharStart: Int
        var absoluteCharEnd: Int
    }

    struct Jump {
        var top: CGFloat
        var bottom: CGFloat
        var absoluteCharStart: Int
        var absoluteCharEnd: Int
        var target: Int
    }

    case text(Text)
    case chapter(Chapter)
    case image(Image)
    case space(Space)
    case jump(Jump)
}

struct ReaderPage {
    let index: Int
    let elements: [PageElement]
    let charStart: Int
    let charEnd: Int
    let chapterTitle: String?

    func containsChar(_ absoluteCharIndex: Int) -> Bool {
        absoluteCharIndex >= charStart && absoluteCharIndex <= charEnd
    }
}

struct PageGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var paddingLeft: CGFloat
    var paddingTop: CGFloat
    var paddingRight: CGFloat
    var paddingBottom: CGFloat

    var contentWidth: CGFloat { width - paddingLeft - paddingRight }
    var contentHeight: CGFloat { height - paddingTop - paddingBottom }
}

// MARK: - Search

struct ReaderSearchHit: Equatable {
    let absoluteStart: Int
    let absoluteEnd: Int
    /// Page that contains the hit (paged mode); -1 until annotated.
    var pageIndex: Int = -1
    let snippet: String
}

/// Overlay highlight range pushed into text blocks (search hits + annotations).
struct HighlightRange: Equatable {
    let absoluteStart: Int
    let absoluteEnd: Int
    let color: UIColor
    var isCurrent: Bool = false
}

enum ReaderSearchEngine {
    static let maxHits = 2000
    static let snippetRadius = 18

    static func search(sourceText: String, query: String, regex: Bool, caseSensitive: Bool = false) -> [ReaderSearchHit] {
        guard !query.isEmpty else { return [] }
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = sourceText as NSString
        var hits: [ReaderSearchHit] = []
        re.enumerateMatches(in: sourceText, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m, m.range.length > 0 else { return }
            hits.append(ReaderSearchHit(
                absoluteStart: m.range.location,
                absoluteEnd: m.range.location + m.range.length,
                snippet: snippet(around: m.range, in: ns)
            ))
            if hits.count >= maxHits { stop.pointee = true }
        }
        return hits
    }

    private static func snippet(around range: NSRange, in ns: NSString) -> String {
        let start = max(0, range.location - snippetRadius)
        let end = min(ns.length, range.location + range.length + snippetRadius)
        var r = NSRange(location: start, length: end - start)
        // Snap to composed character boundaries so we never split a surrogate pair.
        r = ns.rangeOfComposedCharacterSequences(for: r)
        return ns.substring(with: r)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Binary-search pages to stamp each hit with its containing page index.
    static func annotatePageIndices(hits: [ReaderSearchHit], pages: [ReaderPage]) -> [ReaderSearchHit] {
        guard !pages.isEmpty else { return hits }
        return hits.map { hit in
            var h = hit
            var lo = 0, hi = pages.count - 1, found = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let p = pages[mid]
                if hit.absoluteStart < p.charStart {
                    hi = mid - 1
                } else if hit.absoluteStart > p.charEnd {
                    lo = mid + 1
                } else {
                    found = mid
                    break
                }
            }
            // A hit falling in the gap between two pages' char ranges attaches to
            // the following page (clamped to the last) — matches upstream's
            // forward-cursor assignment rather than leaving it un-jumpable (-1).
            h.pageIndex = found >= 0 ? found : min(lo, pages.count - 1)
            return h
        }
    }
}

// MARK: - ContentParser

enum ReaderContentParser {
    private static let uploadedImageRegex = try! NSRegularExpression(pattern: #"\[uploadedimage:(\d+)]"#)
    private static let pixivImageRegex = try! NSRegularExpression(pattern: #"\[pixivimage:(\d+)(?:-(\d+))?]"#)
    private static let chapterRegex = try! NSRegularExpression(pattern: #"\[chapter:(.+?)]"#)
    private static let jumpRegex = try! NSRegularExpression(pattern: #"\[jump:(\d+)]"#)
    private static let newpageTag = "[newpage]"

    // 部分作品章节标题里数字两侧出现多余的直/弯单引号（「第'0章'」）。规则与
    // 上游一致：标题含数字时剥掉所有直/弯单引号；CJK 引号保留。
    private static let singleQuotesRegex = try! NSRegularExpression(pattern: "['‘’]")
    private static let digitRegex = try! NSRegularExpression(pattern: #"\d"#)

    static func cleanChapterTitle(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = NSRange(location: 0, length: (s as NSString).length)
        guard digitRegex.firstMatch(in: s, range: full) != nil else { return s }
        return singleQuotesRegex.stringByReplacingMatches(in: s, range: full, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokenize(_ text: String) -> [ContentToken] {
        guard !text.isEmpty else { return [] }
        var raw: [ContentToken] = []
        raw.reserveCapacity(128)
        var cursor = 0
        for line in text.components(separatedBy: "\n") {
            let lineStart = cursor
            let lineEnd = lineStart + line.utf16.count
            cursor = lineEnd + 1 // the \n that split consumed

            // Pixiv uses \r\n endings — strip the CR that survives the \n split.
            let cleanLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let trimmed = cleanLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Authors often hand-indent with `　`/space; the auto first-line
            // indent owns the offset, so trim manual indent here.
            let paragraphText = String(cleanLine.drop { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })

            if trimmed == newpageTag {
                raw.append(.pageBreak(sourceStart: lineStart, sourceEnd: lineEnd))
            } else if let m = matchEntire(jumpRegex, trimmed) {
                let target = Int((trimmed as NSString).substring(with: m.range(at: 1))) ?? 0
                raw.append(.jump(sourceStart: lineStart, sourceEnd: lineEnd, target: target))
            } else if let m = firstMatch(chapterRegex, trimmed) {
                let title = cleanChapterTitle((trimmed as NSString).substring(with: m.range(at: 1)))
                raw.append(.chapter(sourceStart: lineStart, sourceEnd: lineEnd, title: title))
            } else if let m = firstMatch(uploadedImageRegex, trimmed) {
                let id = Int64((trimmed as NSString).substring(with: m.range(at: 1))) ?? 0
                raw.append(.uploadedImage(sourceStart: lineStart, sourceEnd: lineEnd, imageId: id))
            } else if let m = firstMatch(pixivImageRegex, trimmed) {
                let ns = trimmed as NSString
                let id = Int64(ns.substring(with: m.range(at: 1))) ?? 0
                let page = m.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 2))) ?? 0) : 0
                raw.append(.pixivImage(sourceStart: lineStart, sourceEnd: lineEnd, illustId: id, pageIndex: page))
            } else if trimmed.isEmpty {
                raw.append(.blankLine(sourceStart: lineStart, sourceEnd: lineEnd))
            } else if cleanLine.contains("[jump:"), firstMatch(jumpRegex, cleanLine) != nil {
                // Inline `[jump:N]` at the end of CYOA option lines — split
                // into Paragraph fragments interleaved with Jump tokens.
                splitInlineJumps(cleanLine: cleanLine, lineStart: lineStart, lineEnd: lineEnd, out: &raw)
            } else {
                let textSourceStart = lineStart + (cleanLine.utf16.count - paragraphText.utf16.count)
                let processed = InlineMarkupProcessor.process(paragraphText)
                raw.append(.paragraph(
                    sourceStart: lineStart, sourceEnd: lineEnd,
                    text: processed.text, textSourceStart: textSourceStart,
                    inlineSpans: processed.spans
                ))
            }
        }
        return coalesceParagraphBreaks(raw)
    }

    private static func matchEntire(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        let len = (s as NSString).length
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: len)),
              m.range.location == 0, m.range.length == len else { return nil }
        return m
    }

    private static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func splitInlineJumps(cleanLine: String, lineStart: Int, lineEnd: Int, out: inout [ContentToken]) {
        let ns = cleanLine as NSString
        let matches = jumpRegex.matches(in: cleanLine, range: NSRange(location: 0, length: ns.length))
        var segStart = 0
        for (idx, m) in matches.enumerated() {
            if m.range.location > segStart {
                let frag = ns.substring(with: NSRange(location: segStart, length: m.range.location - segStart))
                let display: String
                let displayStartInFrag: Int
                if idx == 0 {
                    let ts = String(frag.drop { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
                    display = ts
                    displayStartInFrag = frag.utf16.count - ts.utf16.count
                } else {
                    display = frag
                    displayStartInFrag = 0
                }
                if !display.isEmpty {
                    let processed = InlineMarkupProcessor.process(display)
                    out.append(.paragraph(
                        sourceStart: lineStart + segStart,
                        sourceEnd: lineStart + m.range.location,
                        text: processed.text,
                        textSourceStart: lineStart + segStart + displayStartInFrag,
                        inlineSpans: processed.spans
                    ))
                }
            }
            let target = Int(ns.substring(with: m.range(at: 1))) ?? 0
            out.append(.jump(
                sourceStart: lineStart + m.range.location,
                sourceEnd: lineStart + m.range.location + m.range.length,
                target: target
            ))
            segStart = m.range.location + m.range.length
        }
        if segStart < ns.length {
            let frag = ns.substring(from: segStart)
            if !frag.isEmpty {
                let processed = InlineMarkupProcessor.process(frag)
                out.append(.paragraph(
                    sourceStart: lineStart + segStart,
                    sourceEnd: lineEnd,
                    text: processed.text,
                    textSourceStart: lineStart + segStart,
                    inlineSpans: processed.spans
                ))
            }
        }
    }

    /// `\n\n` is the conventional paragraph separator, not "paragraph + blank
    /// line" — drop the FIRST BlankLine directly following a Paragraph so the
    /// paragraph-spacing gap doesn't compound. Extra BlankLines stay.
    private static func coalesceParagraphBreaks(_ raw: [ContentToken]) -> [ContentToken] {
        var out: [ContentToken] = []
        out.reserveCapacity(raw.count)
        var swallowedParagraphBreak = false
        for tok in raw {
            if case .blankLine = tok {
                if case .paragraph = out.last, !swallowedParagraphBreak {
                    swallowedParagraphBreak = true
                    continue
                }
                out.append(tok)
            } else {
                swallowedParagraphBreak = false
                out.append(tok)
            }
        }
        return out
    }

    /// Chapter outline mixing explicit `[chapter:]` entries with
    /// `[newpage]`-derived "分页 N" entries; a synthetic "前言" / "分页 1"
    /// fronts the list when content precedes every anchor.
    static func buildChapterOutline(_ tokens: [ContentToken], pagedLabel: (Int) -> String, prefaceLabel: String) -> [ChapterOutlineEntry] {
        var outline: [ChapterOutlineEntry] = []
        let hasPageBreaks = tokens.contains { if case .pageBreak = $0 { return true } else { return false } }
        var firstContentAnchored = false
        var breaksSeen = 0
        for (i, token) in tokens.enumerated() {
            switch token {
            case .chapter(let start, _, let title):
                outline.append(ChapterOutlineEntry(title: title, sourceStart: start))
                firstContentAnchored = true
            case .pageBreak(_, let end):
                breaksSeen += 1
                // Skip when the next meaningful token is a Chapter — avoids a
                // duplicate "分页 N" + chapter-title pair.
                let next = tokens[(i + 1)...].first { if case .blankLine = $0 { return false } else { return true } }
                if let next, case .chapter = next {
                    firstContentAnchored = true
                    continue
                }
                outline.append(ChapterOutlineEntry(title: pagedLabel(breaksSeen + 1), sourceStart: end))
                firstContentAnchored = true
            case .paragraph, .pixivImage, .uploadedImage, .jump:
                if !firstContentAnchored {
                    outline.append(ChapterOutlineEntry(
                        title: hasPageBreaks ? pagedLabel(1) : prefaceLabel,
                        sourceStart: token.sourceStart
                    ))
                    firstContentAnchored = true
                }
            default:
                break
            }
        }
        return outline
    }

    /// Resolve a `[jump:N]` target (1-indexed `[newpage]` segment) to the
    /// source char offset where that segment begins; nil when out of range.
    static func resolveJumpTarget(_ tokens: [ContentToken], target: Int) -> Int? {
        if target < 1 { return nil }
        if target == 1 { return tokens.first?.sourceStart ?? 0 }
        var seen = 0
        for token in tokens {
            if case .pageBreak(_, let end) = token {
                seen += 1
                if seen == target - 1 { return end }
            }
        }
        return nil
    }
}
