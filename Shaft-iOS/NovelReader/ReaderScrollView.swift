import UIKit

// Vertical-scroll reading mode — 1:1 port of upstream `NovelScrollReaderView`
// (RecyclerView + ContentAdapter): one row per token, paragraph rows are
// selectable text views with link spans, [newpage] becomes a centred divider
// (1.5pt, 25% side insets), blank lines become max(paragraphSpacing,
// fontHeight) spacers, images load full-width with aspect fit, jumps are
// bordered pills. Progress reports as scroll fraction + top-visible char.

final class NovelScrollReaderView: UIView, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    enum Row {
        case paragraph(text: String, spans: [InlineSpan], absoluteStart: Int, sourceStart: Int)
        case chapter(title: String, sourceStart: Int)
        case spacer(sourceStart: Int)
        case divider(sourceStart: Int)
        case image(element: PageElement.Image, sourceStart: Int)
        case jump(target: Int, sourceStart: Int)

        var sourceStart: Int {
            switch self {
            case .paragraph(_, _, _, let s), .chapter(_, let s), .spacer(let s),
                 .divider(let s), .image(_, let s), .jump(_, let s):
                return s
            }
        }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var rows: [Row] = []
    private var style: ReaderTypeStyle?
    private var horizontalMargin: CGFloat = 20
    private var overlays: [HighlightRange] = []
    /// Extra top offset applied to programmatic jumps (search overlay height).
    var topInset: CGFloat = 0

    private static let smoothScrollMaxItems = 40

    var touchLocked = false
    var menuStrings = ReaderMenuStrings()
    var onCenterTap: (() -> Void)?
    var onScrollProgressChanged: ((Double, Int) -> Void)?
    var onJumpTap: ((Int) -> Void)?
    var onImageTap: ((PageElement.Image) -> Void)?
    var onLinkTap: ((URL) -> Void)?
    var onSelectionAction: ((ReaderSelectionAction, ReaderTextSelection) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        tableView.frame = bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false
        tableView.contentInsetAdjustmentBehavior = .never
        addSubview(tableView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(tokens: [ContentToken], style: ReaderTypeStyle, horizontalMargin: CGFloat, verticalMargin: CGFloat,
              safeTop: CGFloat, safeBottom: CGFloat, imageUrlResolver: (ContentToken) -> String?) {
        self.style = style
        self.horizontalMargin = horizontalMargin
        backgroundColor = style.theme.backgroundColor
        tableView.contentInset = UIEdgeInsets(
            top: safeTop + verticalMargin, left: 0,
            bottom: safeBottom + verticalMargin, right: 0
        )

        var built: [Row] = []
        built.reserveCapacity(tokens.count)
        for token in tokens {
            switch token {
            case .paragraph(let start, _, let text, let textSourceStart, let spans):
                built.append(.paragraph(text: text, spans: spans, absoluteStart: textSourceStart, sourceStart: start))
            case .chapter(let start, _, let title):
                built.append(.chapter(title: title, sourceStart: start))
            case .blankLine(let start, _):
                built.append(.spacer(sourceStart: start))
            case .pageBreak(let start, _):
                built.append(.divider(sourceStart: start))
            case .pixivImage(let start, let end, let illustId, let pageIndex):
                built.append(.image(element: PageElement.Image(
                    top: 0, bottom: 0, absoluteCharStart: start, absoluteCharEnd: end,
                    imageType: .pixivImage, resourceId: illustId, pageIndexInIllust: pageIndex,
                    imageUrl: imageUrlResolver(token)
                ), sourceStart: start))
            case .uploadedImage(let start, let end, let imageId):
                built.append(.image(element: PageElement.Image(
                    top: 0, bottom: 0, absoluteCharStart: start, absoluteCharEnd: end,
                    imageType: .uploadedImage, resourceId: imageId, pageIndexInIllust: 0,
                    imageUrl: imageUrlResolver(token)
                ), sourceStart: start))
            case .jump(let start, _, let target):
                built.append(.jump(target: target, sourceStart: start))
            }
        }
        rows = built
        tableView.reloadData()
    }

    func applyOverlays(_ overlays: [HighlightRange]) {
        self.overlays = overlays
        for cell in tableView.visibleCells {
            (cell as? ScrollParagraphCell)?.applyOverlays(overlays)
        }
    }

    func scrollToCharIndex(_ charIndex: Int, animated: Bool) {
        guard !rows.isEmpty else { return }
        // Last row starting at or before the anchor — the row containing it.
        var target = 0
        for (i, row) in rows.enumerated() {
            if row.sourceStart <= charIndex { target = i } else { break }
        }
        let current = tableView.indexPathsForVisibleRows?.first?.row ?? 0
        let canAnimate = animated && abs(target - current) <= Self.smoothScrollMaxItems
        tableView.scrollToRow(at: IndexPath(row: target, section: 0), at: .top, animated: canAnimate)
        if topInset > 0 {
            tableView.contentOffset.y -= topInset
        }
    }

    func setScrollFraction(_ fraction: Double) {
        let range = tableView.contentSize.height + tableView.contentInset.top + tableView.contentInset.bottom - tableView.bounds.height
        guard range > 0 else { return }
        let y = -tableView.contentInset.top + CGFloat(fraction) * range
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let style else { return UITableViewCell() }
        let row = rows[indexPath.row]
        switch row {
        case .paragraph(let text, let spans, let absoluteStart, _):
            let cell = dequeue(ScrollParagraphCell.self, "p")
            cell.configure(text: text, spans: spans, absoluteStart: absoluteStart, style: style,
                           hMargin: horizontalMargin, menuStrings: menuStrings)
            cell.textBlock.onSelectionAction = { [weak self] a, s in self?.onSelectionAction?(a, s) }
            cell.textBlock.onLinkTap = { [weak self] url in self?.onLinkTap?(url) }
            cell.applyOverlays(overlays)
            return cell
        case .chapter(let title, _):
            let cell = dequeue(ScrollChapterCell.self, "c")
            cell.configure(title: title, style: style, hMargin: horizontalMargin)
            return cell
        case .spacer:
            let cell = dequeue(ScrollSpacerCell.self, "s")
            cell.configure(height: max(style.paragraphSpacing, style.fontHeight))
            return cell
        case .divider:
            let cell = dequeue(ScrollDividerCell.self, "d")
            cell.configure(style: style, hMargin: horizontalMargin)
            return cell
        case .image(let element, _):
            let cell = dequeue(ScrollImageCell.self, "i")
            cell.configure(element: element, style: style, hMargin: horizontalMargin)
            cell.onHeightChange = { [weak tableView] in
                tableView?.beginUpdates()
                tableView?.endUpdates()
            }
            cell.onTap = { [weak self] in self?.onImageTap?(element) }
            return cell
        case .jump(let target, _):
            let cell = dequeue(ScrollJumpCell.self, "j")
            cell.configure(target: target, style: style, hMargin: horizontalMargin)
            cell.onTap = { [weak self] in self?.onJumpTap?(target) }
            return cell
        }
    }

    private func dequeue<T: UITableViewCell>(_ type: T.Type, _ id: String) -> T {
        (tableView.dequeueReusableCell(withIdentifier: id) as? T) ?? T(style: .default, reuseIdentifier: id)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Skip the spurious zero reports fired while the table is still
        // laying out after bind — they'd clobber the saved reading anchor.
        guard window != nil, scrollView.contentSize.height > 0 else { return }
        let range = scrollView.contentSize.height + scrollView.contentInset.top + scrollView.contentInset.bottom - scrollView.bounds.height
        let progress = range > 0 ? Double((scrollView.contentOffset.y + scrollView.contentInset.top) / range) : 0
        let charIndex = tableView.indexPathsForVisibleRows?.first.map { rows[$0.row].sourceStart } ?? 0
        onScrollProgressChanged?(min(max(progress, 0), 1), charIndex)
    }

    // MARK: Tap

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { !touchLocked }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let v = view {
            if v is UIControl { return false }
            view = v.superview
        }
        return true
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let x = g.location(in: self).x
        let third = bounds.width / 3
        guard x >= third, x <= bounds.width - third else { return }
        // Don't toggle chrome while a selection is active.
        for cell in tableView.visibleCells {
            if let p = cell as? ScrollParagraphCell, p.textBlock.hasSelection { return }
        }
        onCenterTap?()
    }
}

// MARK: - Cells

final class ScrollParagraphCell: UITableViewCell {
    let textBlock = ReaderTextBlockView(frame: .zero, textContainer: nil)
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        textBlock.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textBlock)
        leading = textBlock.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20)
        trailing = textBlock.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        bottom = textBlock.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        NSLayoutConstraint.activate([
            textBlock.topAnchor.constraint(equalTo: contentView.topAnchor),
            leading, trailing, bottom,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, spans: [InlineSpan], absoluteStart: Int, style: ReaderTypeStyle, hMargin: CGFloat, menuStrings: ReaderMenuStrings) {
        leading.constant = hMargin
        trailing.constant = -hMargin
        bottom.constant = -style.paragraphSpacing
        textBlock.menuStrings = menuStrings
        textBlock.bind(paragraph: text, spans: spans, absoluteStart: absoluteStart, style: style)
    }

    func applyOverlays(_ overlays: [HighlightRange]) {
        textBlock.applyOverlayHighlights(overlays)
    }
}

final class ScrollChapterCell: UITableViewCell {
    private let label = UILabel()
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        top = label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24)
        bottom = label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32)
        leading = label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20)
        trailing = label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        NSLayoutConstraint.activate([top, bottom, leading, trailing])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, style: ReaderTypeStyle, hMargin: CGFloat) {
        top.constant = style.chapterTopGap
        bottom.constant = -style.chapterBottomGap
        leading.constant = hMargin
        trailing.constant = -hMargin
        label.attributedText = NSAttributedString(string: title.isEmpty ? "  " : title, attributes: style.chapterAttributes())
    }
}

final class ScrollSpacerCell: UITableViewCell {
    private var height: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(v)
        height = v.heightAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentView.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            height,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(height h: CGFloat) {
        height.constant = h
    }
}

final class ScrollDividerCell: UITableViewCell {
    private let line = UIView()
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        line.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(line)
        top = line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24)
        bottom = line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        leading = line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 80)
        trailing = line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -80)
        NSLayoutConstraint.activate([
            top, bottom, leading, trailing,
            line.heightAnchor.constraint(equalToConstant: 1.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(style: ReaderTypeStyle, hMargin: CGFloat) {
        line.backgroundColor = style.theme.dividerColor
        // Upstream: 25% content-width side insets, 0.8 × chapterTopGap above/below.
        let contentWidth = UIScreen.main.bounds.width - hMargin * 2
        leading.constant = hMargin + contentWidth * 0.25
        trailing.constant = -(hMargin + contentWidth * 0.25)
        top.constant = style.chapterTopGap * 0.8
        bottom.constant = -style.chapterTopGap * 0.8
    }
}

final class ScrollImageCell: UITableViewCell {
    private let imgView = UIImageView()
    private var aspect: NSLayoutConstraint?
    private var vGapTop: NSLayoutConstraint!
    private var vGapBottom: NSLayoutConstraint!
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var loadTask: Task<Void, Never>?
    private var boundURL: String?

    var onHeightChange: (() -> Void)?
    var onTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        imgView.contentMode = .scaleAspectFit
        imgView.clipsToBounds = true
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.isUserInteractionEnabled = true
        contentView.addSubview(imgView)
        vGapTop = imgView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        vGapBottom = imgView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        leading = imgView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20)
        trailing = imgView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        NSLayoutConstraint.activate([vGapTop, vGapBottom, leading, trailing])
        setAspect(0.6)
        imgView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setAspect(_ heightOverWidth: CGFloat) {
        aspect?.isActive = false
        aspect = imgView.heightAnchor.constraint(equalTo: imgView.widthAnchor, multiplier: heightOverWidth)
        aspect?.priority = .init(999)
        aspect?.isActive = true
    }

    func configure(element: PageElement.Image, style: ReaderTypeStyle, hMargin: CGFloat) {
        leading.constant = hMargin
        trailing.constant = -hMargin
        vGapTop.constant = style.paragraphSpacing
        vGapBottom.constant = -style.paragraphSpacing
        imgView.backgroundColor = style.theme.dividerColor.withAlphaComponent(0.3)
        loadTask?.cancel()
        guard let urlString = element.imageUrl, let url = URL(string: urlString) else {
            imgView.image = nil
            return
        }
        if boundURL == urlString, imgView.image != nil { return }
        boundURL = urlString
        imgView.image = nil
        loadTask = Task { [weak self] in
            let image = await PixivImageCache.shared.load(url)
            guard !Task.isCancelled, let self, let image else { return }
            self.imgView.image = image
            self.imgView.backgroundColor = .clear
            if image.size.width > 0 {
                self.setAspect(image.size.height / image.size.width)
                self.onHeightChange?()
            }
        }
    }

    @objc private func tapped() { onTap?() }
}

final class ScrollJumpCell: UITableViewCell {
    private let pill = UIView()
    private let label = UILabel()
    private var heightC: NSLayoutConstraint!
    private var vTop: NSLayoutConstraint!
    private var vBottom: NSLayoutConstraint!
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    var onTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        pill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pill)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        vTop = pill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        vBottom = pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        leading = pill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 56)
        trailing = pill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -56)
        heightC = pill.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            vTop, vBottom, leading, trailing, heightC,
            label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        pill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        pill.isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(target: Int, style: ReaderTypeStyle, hMargin: CGFloat) {
        let size = style.bodyFont.pointSize
        vTop.constant = style.paragraphSpacing
        vBottom.constant = -style.paragraphSpacing
        leading.constant = hMargin + size * 2
        trailing.constant = -(hMargin + size * 2)
        heightC.constant = size * 2.4
        pill.layer.borderColor = style.theme.linkColor.cgColor
        pill.layer.borderWidth = 2
        pill.layer.cornerRadius = size * 1.2
        label.font = style.bodyFont
        label.textColor = style.theme.linkColor
        label.text = ReaderJumpButton.labelFormat(target)
    }

    @objc private func tapped() { onTap?() }
}
