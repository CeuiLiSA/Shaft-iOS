import UIKit

// Render primitives for the V3 reader — 1:1 port of upstream
// ReaderTextBlockView / PageView / PageRenderer:
// - ReaderTextBlockView: selectable text host; consecutive paragraph slices
//   merge into one view with exact pixel gaps, overlay highlights are
//   background-color attributes, custom edit-menu actions bubble up.
// - ReaderPageView: one page — text blocks as subviews, chapter headings
//   (1.55× centred + 35%→65% underline), full-page images (fit/fill/original),
//   `[jump:N]` pill buttons, theme background.

// MARK: - Selection menu plumbing

struct ReaderMenuStrings {
    var searchPixiv = ""
    var searchWeb = ""
    var highlight = ""
    var note = ""
    var highlightColorNames: [String] = []
}

enum ReaderSelectionAction {
    case searchPixiv
    case searchWeb
    case highlight(ReaderHighlightColor)
    case note
}

/// Absolute (source-text) selection emitted from a text block.
struct ReaderTextSelection {
    let absoluteStart: Int
    let absoluteEnd: Int
    let text: String
}

// MARK: - ReaderTextBlockView

final class ReaderTextBlockView: UITextView, UITextViewDelegate {
    private struct Segment {
        let localStart: Int
        let localEnd: Int
        let absoluteStart: Int
    }

    private var segments: [Segment] = []
    private var baseAttributed: NSMutableAttributedString?

    var menuStrings = ReaderMenuStrings()
    var onSelectionAction: ((ReaderSelectionAction, ReaderTextSelection) -> Void)?
    var onLinkTap: ((URL) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // Pin to TextKit 1: the paginator measures line breaks with NSLayoutManager
        // (TextKit 1), so touching `.layoutManager` forces this text view off the
        // iOS 16+ TextKit 2 path and renders identical wrapping to the measured
        // slices (otherwise characters can drift across page boundaries).
        _ = layoutManager
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Selection is long-press only (#1150). Page views are pooled across
    /// flips, so two quick page-turn taps can land on the same text view and
    /// the system's double-/triple-tap word selection would pick a word on the
    /// new page. Multi-tap recognizers only start while a selection is already
    /// live (where they extend it, as before).
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let tap = g as? UITapGestureRecognizer, tap.numberOfTapsRequired >= 2,
           selectedRange.length == 0 {
            return false
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// Bind a group of consecutive paragraph slices (paged mode). Pixel gaps
    /// between slices become `paragraphSpacing` so positions match the
    /// paginator exactly; first-line indent re-applies per slice flag.
    func bind(slices: [PageElement.Text], style: ReaderTypeStyle) {
        let sb = NSMutableAttributedString()
        segments.removeAll()
        for (idx, slice) in slices.enumerated() {
            let text = slice.text.hasSuffix("\n") ? String(slice.text.dropLast()) : slice.text
            let localStart = sb.length
            let attrs = style.bodyAttributes(indentFirstLine: slice.isFirstLineOfParagraph)
            var sliceAttrs = attrs
            if idx < slices.count - 1 {
                let gap = max(slices[idx + 1].top - slice.bottom, 0)
                let p = (attrs[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacing = gap
                sliceAttrs[.paragraphStyle] = p
            }
            sb.append(NSAttributedString(string: text, attributes: sliceAttrs))
            segments.append(Segment(localStart: localStart, localEnd: sb.length, absoluteStart: slice.absoluteCharStart))
            if idx < slices.count - 1 {
                sb.append(NSAttributedString(string: "\n", attributes: sliceAttrs))
            }
        }
        baseAttributed = sb
        attributedText = sb
        tintColor = style.theme.accentColor
        linkTextAttributes = [
            .foregroundColor: style.theme.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    /// Bind a single full paragraph (scroll mode) with inline link spans.
    func bind(paragraph text: String, spans: [InlineSpan], absoluteStart: Int, style: ReaderTypeStyle) {
        let sb = NSMutableAttributedString(string: text, attributes: style.bodyAttributes(indentFirstLine: true))
        for span in spans {
            let r = NSRange(location: span.start, length: span.end - span.start)
            guard r.location + r.length <= sb.length else { continue }
            if case .link(let url) = span.tag, let u = URL(string: url) {
                sb.addAttribute(.link, value: u, range: r)
            }
            // Ruby annotations degrade to plain base text (upstream parity).
        }
        segments = [Segment(localStart: 0, localEnd: sb.length, absoluteStart: absoluteStart)]
        baseAttributed = sb
        attributedText = sb
        tintColor = style.theme.accentColor
        linkTextAttributes = [
            .foregroundColor: style.theme.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    /// Re-apply overlay highlights (search hits + annotations) as background
    /// colors over the base attributed text.
    func applyOverlayHighlights(_ hits: [HighlightRange]) {
        guard let base = baseAttributed else { return }
        let withHighlights = NSMutableAttributedString(attributedString: base)
        for hit in hits {
            for seg in segments {
                let segAbsEnd = seg.absoluteStart + (seg.localEnd - seg.localStart)
                let s = max(hit.absoluteStart, seg.absoluteStart)
                let e = min(hit.absoluteEnd, segAbsEnd)
                guard e > s else { continue }
                let local = NSRange(location: seg.localStart + (s - seg.absoluteStart), length: e - s)
                guard local.location + local.length <= withHighlights.length else { continue }
                withHighlights.addAttribute(.backgroundColor, value: hit.color, range: local)
            }
        }
        let selection = selectedRange
        attributedText = withHighlights
        if selection.length > 0 { selectedRange = selection }
    }

    var hasSelection: Bool { selectedRange.length > 0 }

    func currentSelection() -> ReaderTextSelection? {
        let r = selectedRange
        guard r.length > 0, let seg = segment(forLocal: r.location) else { return nil }
        let absStart = seg.absoluteStart + (r.location - seg.localStart)
        // Selection may span segments; map the end through its own segment.
        let endSeg = segment(forLocal: max(r.location, r.location + r.length - 1)) ?? seg
        let absEnd = endSeg.absoluteStart + (r.location + r.length - endSeg.localStart)
        let text = (attributedText.string as NSString).substring(with: r)
        return ReaderTextSelection(absoluteStart: absStart, absoluteEnd: absEnd, text: text)
    }

    /// Absolute source char under `point` (this view's coordinates); nil when
    /// the point is outside every laid-out line (TTS double-tap, #1139).
    func absoluteCharIndex(at point: CGPoint) -> Int? {
        guard let text = attributedText, text.length > 0 else { return nil }
        let p = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard p.y >= line.minY, p.y <= line.maxY else { return nil }
        let local = min(layoutManager.characterIndexForGlyph(at: glyph), text.length - 1)
        guard let seg = segment(forLocal: local) else { return nil }
        return seg.absoluteStart + min(local - seg.localStart, seg.localEnd - seg.localStart)
    }

    /// Line rect (this view's coordinates) containing absolute char `index`, if it lives here.
    func lineRect(forAbsoluteChar index: Int) -> CGRect? {
        guard let seg = segments.first(where: { index >= $0.absoluteStart && index < $0.absoluteStart + ($0.localEnd - $0.localStart) }) else { return nil }
        let local = seg.localStart + (index - seg.absoluteStart)
        guard local < (attributedText?.length ?? 0) else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: local)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    private func segment(forLocal local: Int) -> Segment? {
        // Inter-slice "\n" joiners belong to the preceding segment.
        segments.last { local >= $0.localStart } ?? segments.first
    }

    // MARK: Edit menu (iOS 16+)

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else { return UIMenu(children: suggestedActions) }
        var custom: [UIMenuElement] = []
        let colorChildren = ReaderHighlightColor.allCases.enumerated().map { idx, color in
            UIAction(title: menuStrings.highlightColorNames.indices.contains(idx) ? menuStrings.highlightColorNames[idx] : "\(idx)") { [weak self] _ in
                self?.emit(.highlight(color))
            }
        }
        custom.append(UIMenu(title: menuStrings.highlight, children: colorChildren))
        custom.append(UIAction(title: menuStrings.note) { [weak self] _ in self?.emit(.note) })
        custom.append(UIAction(title: menuStrings.searchPixiv) { [weak self] _ in self?.emit(.searchPixiv) })
        custom.append(UIAction(title: menuStrings.searchWeb) { [weak self] _ in self?.emit(.searchWeb) })
        return UIMenu(children: suggestedActions + custom)
    }

    private func emit(_ action: ReaderSelectionAction) {
        guard let sel = currentSelection() else { return }
        onSelectionAction?(action, sel)
        selectedTextRange = nil
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction {
            onLinkTap?(URL)
            return false
        }
        return true
    }
}

// MARK: - ReaderPageView

final class ReaderPageView: UIView {
    private(set) var page: ReaderPage?
    private var style: ReaderTypeStyle?
    private var geometry: PageGeometry?
    private(set) var textBlocks: [ReaderTextBlockView] = []
    private var imageViews: [(element: PageElement.Image, view: UIImageView)] = []
    private var imageTasks: [Task<Void, Never>] = []

    var menuStrings = ReaderMenuStrings()
    var onSelectionAction: ((ReaderSelectionAction, ReaderTextSelection) -> Void)?
    var onJumpTap: ((Int) -> Void)?
    var onImageTap: ((PageElement.Image) -> Void)?
    var onLinkTap: ((URL) -> Void)?

    /// True while any text block has an active selection — gates page flips.
    var hasActiveSelection: Bool { textBlocks.contains { $0.hasSelection } }

    func clearSelection() {
        textBlocks.forEach { $0.selectedTextRange = nil }
    }

    func bind(page: ReaderPage?, style: ReaderTypeStyle, geometry: PageGeometry, overlays: [HighlightRange]) {
        self.page = page
        self.style = style
        self.geometry = geometry
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        subviews.forEach { $0.removeFromSuperview() }
        textBlocks.removeAll()
        imageViews.removeAll()
        backgroundColor = style.theme.backgroundColor
        guard let page else { return }

        var sliceGroup: [PageElement.Text] = []
        func flushTextGroup() {
            guard !sliceGroup.isEmpty else { return }
            let block = ReaderTextBlockView(frame: .zero, textContainer: nil)
            block.menuStrings = menuStrings
            block.onSelectionAction = onSelectionAction
            block.onLinkTap = onLinkTap
            block.bind(slices: sliceGroup, style: style)
            let top = sliceGroup[0].top
            let bottom = sliceGroup[sliceGroup.count - 1].bottom
            block.frame = CGRect(x: geometry.paddingLeft, y: top, width: geometry.contentWidth, height: bottom - top)
            addSubview(block)
            textBlocks.append(block)
            sliceGroup.removeAll()
        }

        for element in page.elements {
            switch element {
            case .text(let t):
                sliceGroup.append(t)
            case .space:
                continue // transparent spacing
            case .chapter(let c):
                flushTextGroup()
                addChapter(c, style: style, geometry: geometry)
            case .image(let img):
                flushTextGroup()
                addImage(img, style: style, geometry: geometry)
            case .jump(let j):
                flushTextGroup()
                addJump(j, style: style, geometry: geometry)
            }
        }
        flushTextGroup()
        applyOverlays(overlays)
    }

    func applyOverlays(_ overlays: [HighlightRange]) {
        textBlocks.forEach { $0.applyOverlayHighlights(overlays) }
    }

    /// Absolute char under `point` — a text block's character, or a chapter
    /// title's start (upstream double-tap resolves a chapter to its sourceStart).
    func absoluteCharIndex(at point: CGPoint) -> Int? {
        for block in textBlocks where block.frame.contains(point) {
            if let index = block.absoluteCharIndex(at: block.convert(point, from: self)) { return index }
        }
        for element in page?.elements ?? [] {
            if case .chapter(let c) = element, point.y >= c.top, point.y <= c.bottom { return c.absoluteCharStart }
        }
        return nil
    }

    private func addChapter(_ c: PageElement.Chapter, style: ReaderTypeStyle, geometry: PageGeometry) {
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(string: c.title.isEmpty ? "  " : c.title, attributes: style.chapterAttributes())
        label.frame = CGRect(x: geometry.paddingLeft, y: c.top, width: geometry.contentWidth, height: c.bottom - c.top)
        addSubview(label)

        // PageRenderer underline: 35%→65% of width, 1.5pt stroke, at
        // bottom + chapterBottomGap × 0.35.
        let underline = UIView()
        underline.backgroundColor = style.theme.dividerColor
        let y = c.bottom + style.chapterBottomGap * 0.35
        underline.frame = CGRect(
            x: geometry.paddingLeft + geometry.contentWidth * 0.35,
            y: y,
            width: geometry.contentWidth * 0.30,
            height: 1.5
        )
        addSubview(underline)
    }

    private func addImage(_ img: PageElement.Image, style: ReaderTypeStyle, geometry: PageGeometry) {
        let container = UIView(frame: CGRect(
            x: geometry.paddingLeft, y: img.top,
            width: geometry.contentWidth, height: img.bottom - img.top
        ))
        container.clipsToBounds = true
        addSubview(container)

        guard let urlString = img.imageUrl, let url = URL(string: urlString) else {
            addImagePlaceholder(into: container, style: style)
            return
        }
        let iv = UIImageView(frame: container.bounds)
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        switch style.imageScaleMode {
        case .fit: iv.contentMode = .scaleAspectFit
        case .fill: iv.contentMode = .scaleAspectFill
        case .original: iv.contentMode = .center
        }
        container.addSubview(iv)
        imageViews.append((img, iv))

        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:)))
        container.addGestureRecognizer(tap)
        container.isUserInteractionEnabled = true
        container.tag = imageViews.count - 1

        let placeholder = makePlaceholder(style: style, bounds: container.bounds)
        container.insertSubview(placeholder, at: 0)
        let task = Task { [weak iv, weak placeholder] in
            let image = await PixivImageCache.shared.load(url)
            guard !Task.isCancelled, let iv else { return }
            iv.image = image
            if image != nil { placeholder?.removeFromSuperview() }
        }
        imageTasks.append(task)
    }

    private func addImagePlaceholder(into container: UIView, style: ReaderTypeStyle) {
        container.addSubview(makePlaceholder(style: style, bounds: container.bounds))
    }

    private func makePlaceholder(style: ReaderTypeStyle, bounds: CGRect) -> UIView {
        let v = UIView(frame: bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.layer.borderColor = style.theme.dividerColor.cgColor
        v.layer.borderWidth = 1.5
        v.layer.cornerRadius = 12
        let label = UILabel(frame: bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.textAlignment = .center
        label.font = style.captionFont
        label.textColor = style.theme.secondaryTextColor
        label.text = "···"
        v.addSubview(label)
        return v
    }

    @objc private func imageTapped(_ g: UITapGestureRecognizer) {
        guard let idx = g.view?.tag, imageViews.indices.contains(idx) else { return }
        onImageTap?(imageViews[idx].element)
    }

    private func addJump(_ j: PageElement.Jump, style: ReaderTypeStyle, geometry: PageGeometry) {
        // PageRenderer.drawJump: 18% side inset, fully-rounded 2pt border in
        // linkColor, centred label.
        let sideInset = geometry.contentWidth * 0.18
        let rect = CGRect(
            x: geometry.paddingLeft + sideInset,
            y: j.top,
            width: geometry.contentWidth - sideInset * 2,
            height: j.bottom - j.top
        )
        let button = ReaderJumpButton(frame: rect)
        button.configure(target: j.target, style: style)
        button.onTap = { [weak self] in self?.onJumpTap?(j.target) }
        addSubview(button)
    }

    func snapshotImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }
    }
}

/// `[jump:N]` pill — border + label in linkColor, transparent fill.
final class ReaderJumpButton: UIControl {
    private let label = UILabel()
    var onTap: (() -> Void)?

    /// Set by the chrome layer so the label is localized.
    static var labelFormat: (Int) -> String = { "→ \($0)" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(target: Int, style: ReaderTypeStyle) {
        layer.borderColor = style.theme.linkColor.cgColor
        layer.borderWidth = 2
        layer.cornerRadius = bounds.height * 0.5
        label.font = style.bodyFont
        label.textColor = style.theme.linkColor
        label.text = Self.labelFormat(target)
    }

    @objc private func tapped() { onTap?() }
}
