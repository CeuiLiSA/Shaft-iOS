import SwiftUI
import UIKit
import QuartzCore

// Paged (horizontal) viewport for the manga reader — the iOS analog of upstream
// `PagedViewport` (ViewPager2 + `ComicPagerAdapter` + `ComicPageTransformers`).
// A horizontally-paging UICollectionView with one zoomable image per cell;
// flip animations are applied as per-cell layer transforms during scroll,
// exactly like ViewPager2.PageTransformer's `position` ∈ [-1, 1] callback.
//
// RTL (right-to-left manga) is the mirror-transform trick on the collection
// view + a counter-mirror on each cell's content. Custom flip animations run
// only under LTR; RTL always uses the plain slide (the common manga case).

enum ComicTapZone { case left, center, right }

// MARK: - Tiled layer view (TileImageSource counterpart of the viewer's private TilingView)

private final class ComicTilingView: UIView {
    private let source: TileImageSource
    override class var layerClass: AnyClass { CATiledLayer.self }

    init(source: TileImageSource) {
        self.source = source
        super.init(frame: CGRect(origin: .zero, size: source.imageSize))
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = source.levelCount
        tiled.levelsOfDetailBias = 2
        tiled.tileSize = CGSize(width: 768, height: 768)
        isOpaque = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override var contentScaleFactor: CGFloat { didSet { super.contentScaleFactor = 1 } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        source.draw(rect: rect, scale: ctx.ctm.a, in: ctx)
    }
}

// MARK: - Zoomable page scroll view (fit-mode aware)

final class ComicZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: ((ComicTapZone) -> Void)?
    var onZoomStateChanged: ((Bool) -> Void)?

    private let imageSize: CGSize
    private let container: UIView
    private let fitMode: ComicReaderSettings.FitMode
    private let doubleTapZoom: CGFloat
    private var lastLayoutSize: CGSize = .zero
    private var configured = false
    private var mediumScale: CGFloat = 1
    private var fitScreenScale: CGFloat = 1
    private var wasZoomed = false

    init(source: TileImageSource, fitMode: ComicReaderSettings.FitMode, doubleTapZoom: CGFloat) {
        imageSize = source.imageSize
        self.fitMode = fitMode
        self.doubleTapZoom = doubleTapZoom
        container = UIView(frame: CGRect(origin: .zero, size: source.imageSize))
        super.init(frame: .zero)

        let base = UIImageView(image: source.baseImage)
        base.frame = container.bounds
        base.contentMode = .scaleToFill
        container.addSubview(base)
        container.addSubview(ComicTilingView(source: source))
        addSubview(container)
        contentSize = imageSize

        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        bouncesZoom = true

        let dbl = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        addGestureRecognizer(dbl)
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        single.require(toFail: dbl)
        addGestureRecognizer(single)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize, bounds.width > 0, bounds.height > 0 {
            lastLayoutSize = bounds.size
            configureScales()
        }
        centerContent()
    }

    private func configureScales() {
        let fitW = bounds.width / imageSize.width
        let fitH = bounds.height / imageSize.height
        fitScreenScale = min(fitW, fitH)
        let initial: CGFloat
        switch fitMode {
        case .fitWidth:    initial = fitW
        case .fitScreen:   initial = fitScreenScale
        case .fitOriginal: initial = min(fitScreenScale, 1.0)   // 1.0 == one image pixel per point
        }
        minimumZoomScale = min(fitScreenScale, initial)
        mediumScale = max(fitScreenScale * doubleTapZoom, initial * 1.2)
        maximumZoomScale = max(mediumScale * 1.5, 3.0)

        if !configured {
            configured = true
            setZoomScale(initial, animated: false)
            if fitMode == .fitWidth { contentOffset = .zero }   // top-align tall pages
        } else {
            zoomScale = min(max(zoomScale, minimumZoomScale), maximumZoomScale)
        }
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        reportZoomState()
    }

    private func reportZoomState() {
        let zoomed = zoomScale > minimumZoomScale + 0.001
        if zoomed != wasZoomed { wasZoomed = zoomed; onZoomStateChanged?(zoomed) }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale < mediumScale - 0.001 {
            let point = g.location(in: container)
            let w = bounds.width / mediumScale
            let h = bounds.height / mediumScale
            zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
        } else {
            setZoomScale(minimumZoomScale, animated: true)
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        let viewportX = g.location(in: self).x - bounds.minX
        let w = bounds.width
        let zone: ComicTapZone
        if w <= 0 { zone = .center }
        else if viewportX < w / 3 { zone = .left }
        else if viewportX > w * 2 / 3 { zone = .right }
        else { zone = .center }
        onSingleTap?(zone)
    }

    // Resolve the nested-scroll conflict with the horizontal pager: at fit scale
    // the page's own pan only claims predominantly-vertical drags (scrolling a
    // tall fit-width page); horizontal drags fall through to the pager. When
    // zoomed in, the page pans freely in every direction.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, pan === panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(g)
        }
        if zoomScale > minimumZoomScale + 0.001 { return true }
        let v = pan.velocity(in: self)
        let scaledHeight = imageSize.height * zoomScale
        return abs(v.y) > abs(v.x) && scaledHeight > bounds.height + 1
    }
}

// MARK: - Paged cell

final class ComicPagedCell: UICollectionViewCell {
    static let reuseId = "ComicPagedCell"

    private let placeholderView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let reloadButton = UIButton(type: .system)
    private var zoomView: ComicZoomScrollView?
    private var loadTask: Task<Void, Never>?
    private var isZoomed = false

    private(set) var pageIndex = 0
    private var fitMode: ComicReaderSettings.FitMode = .fitWidth
    private var doubleTapZoom: CGFloat = 2.5
    private var pageURL: URL?
    private var previewURL: URL?

    var onSingleTap: ((ComicTapZone) -> Void)?
    var onLongPress: ((Int) -> Void)?
    var onZoomStateChanged: ((Int, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false

        placeholderView.contentMode = .scaleAspectFit
        placeholderView.frame = contentView.bounds
        placeholderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(placeholderView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        reloadButton.setImage(UIImage(systemName: "arrow.clockwise",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)), for: .normal)
        reloadButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        reloadButton.isHidden = true
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
        contentView.addSubview(reloadButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            reloadButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            reloadButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        contentView.addGestureRecognizer(lp)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(pageIndex: Int, url: URL?, preview: URL?, rtl: Bool,
                   fitMode: ComicReaderSettings.FitMode, doubleTapZoom: CGFloat) {
        // Clear any lingering zoom state for the OUTGOING page before adopting
        // the new one, so the pager's `zoomedPages` set never wedges paging off.
        clearZoomState()
        self.pageIndex = pageIndex
        self.pageURL = url
        self.previewURL = preview
        self.fitMode = fitMode
        self.doubleTapZoom = doubleTapZoom
        // Counter-mirror the content so RTL reads correctly (and tap zones stay
        // in un-mirrored coordinates).
        contentView.transform = rtl ? CGAffineTransform(scaleX: -1, y: 1) : .identity

        teardownZoom()
        reloadButton.isHidden = true
        // Instant first frame from the memory cache if available.
        placeholderView.image = previewSeed()
        placeholderView.isHidden = false
        spinner.startAnimating()

        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func previewSeed() -> UIImage? {
        (pageURL.flatMap { PixivImageCache.shared.displayImage(for: $0) })
            ?? (previewURL.flatMap { PixivImageCache.shared.image(for: $0) })
    }

    private func load() async {
        guard let url = pageURL else { showError(); return }
        // Upgrade the placeholder from the preview while the original downloads.
        if placeholderView.image == nil, let preview = previewURL {
            if let cached = PixivImageCache.shared.image(for: preview) {
                placeholderView.image = cached
            } else if !PixivImageCache.shared.hasDiskData(for: url) {
                let token = url   // detect a reused cell handed a different page
                Task { [weak self] in
                    guard let img = await PixivImageCache.shared.load(preview) else { return }
                    guard let self, self.pageURL == token, self.zoomView == nil else { return }
                    self.placeholderView.image = img
                }
            }
        }
        guard let data = await PixivImageCache.shared.loadData(url) else {
            if !Task.isCancelled { showError() }
            return
        }
        if Task.isCancelled { return }
        guard let source = await TileImageSource.make(data: data) else {
            if !Task.isCancelled { showError() }
            return
        }
        if Task.isCancelled { return }
        installZoom(source)
    }

    private func installZoom(_ source: TileImageSource) {
        teardownZoom()
        let zv = ComicZoomScrollView(source: source, fitMode: fitMode, doubleTapZoom: doubleTapZoom)
        zv.frame = contentView.bounds
        zv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zv.onSingleTap = { [weak self] zone in self?.onSingleTap?(zone) }
        zv.onZoomStateChanged = { [weak self] zoomed in
            guard let self else { return }
            self.isZoomed = zoomed
            self.onZoomStateChanged?(self.pageIndex, zoomed)
        }
        contentView.insertSubview(zv, belowSubview: spinner)
        zoomView = zv
        spinner.stopAnimating()
        reloadButton.isHidden = true
        placeholderView.isHidden = true
    }

    private func teardownZoom() {
        zoomView?.removeFromSuperview()
        zoomView = nil
    }

    /// Tell the pager this page is no longer zoomed (it's about to be reused or
    /// reconfigured) so it can re-enable paging.
    private func clearZoomState() {
        guard isZoomed else { return }
        isZoomed = false
        onZoomStateChanged?(pageIndex, false)
    }

    private func showError() {
        spinner.stopAnimating()
        reloadButton.isHidden = false
        placeholderView.isHidden = placeholderView.image == nil
    }

    @objc private func reloadTapped() {
        reloadButton.isHidden = true
        spinner.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { onLongPress?(pageIndex) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        clearZoomState()
        teardownZoom()
        placeholderView.image = nil
        placeholderView.isHidden = false
        reloadButton.isHidden = true
        spinner.stopAnimating()
        layer.transform = CATransform3DIdentity
        layer.zPosition = 0
        contentView.alpha = 1
    }

    /// Reset the flip transform (e.g. switching to slide / RTL).
    func resetFlipTransform() {
        layer.transform = CATransform3DIdentity
        layer.zPosition = 0
        contentView.alpha = 1
    }
}

// MARK: - Flip transformers (ComicPageTransformers parity)

enum ComicFlipTransformer {
    static func apply(_ anim: ComicReaderSettings.FlipAnim, to cell: ComicPagedCell,
                      position p: CGFloat, width: CGFloat) {
        let layer = cell.layer
        switch anim {
        case .slide:
            cell.resetFlipTransform()

        case .cover:
            layer.zPosition = p <= 0 ? 1 : 0
            let tx = p > 0 ? -p * width : 0
            layer.transform = CATransform3DMakeTranslation(tx, 0, 0)
            cell.contentView.alpha = 1

        case .depth:
            if p < -1 || p > 1 { cell.contentView.alpha = 0; return }
            layer.zPosition = 0
            if p <= 0 {
                layer.transform = CATransform3DIdentity
                cell.contentView.alpha = 1
            } else {
                cell.contentView.alpha = 1 - p
                let scale = 0.75 + (1 - 0.75) * (1 - abs(p))
                var t = CATransform3DMakeTranslation(-width * p, 0, 0)
                t = CATransform3DScale(t, scale, scale, 1)
                layer.transform = t
            }

        case .flipBook:
            if p < -1 || p > 1 { cell.contentView.alpha = 0; return }
            layer.zPosition = p <= 0 ? 1 : 0
            if p <= 0 {
                layer.transform = CATransform3DIdentity
                cell.contentView.alpha = 1
            } else {
                cell.contentView.alpha = max(0, 1 - p)
                let angle = -CGFloat.pi / 2 * p          // 0 → -90°, right-edge pivot
                var t = CATransform3DIdentity
                t.m34 = -1.0 / 2500
                t = CATransform3DTranslate(t, -width / 2, 0, 0)
                t = CATransform3DRotate(t, angle, 0, 1, 0)
                t = CATransform3DTranslate(t, width / 2, 0, 0)
                t = CATransform3DTranslate(t, -width * p, 0, 0)   // keep fixed on screen
                layer.transform = t
            }
        }
    }
}

// MARK: - Collection view (handles first-layout positioning)

final class ComicPagedCollectionView: UICollectionView {
    var pendingInitialIndex: Int?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        let sizeChanged = bounds.size != lastBoundsSize
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if sizeChanged {
            lastBoundsSize = bounds.size
            collectionViewLayout.invalidateLayout()
        }
        if let idx = pendingInitialIndex, numberOfItems(inSection: 0) > idx {
            pendingInitialIndex = nil
            layoutIfNeeded()
            scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredHorizontally, animated: false)
        }
    }
}

// MARK: - Representable

struct ComicPagedContainer: UIViewRepresentable {
    let pages: [ComicReaderViewModel.ComicPage]
    let urlFor: (ComicReaderViewModel.ComicPage) -> URL?
    let previewFor: (ComicReaderViewModel.ComicPage) -> URL?
    let direction: ComicReaderSettings.PageDirection
    let fitMode: ComicReaderSettings.FitMode
    let flipAnim: ComicReaderSettings.FlipAnim
    let loadOriginal: Bool
    let doubleTapZoom: CGFloat
    let initialPage: Int
    let command: ComicReaderViewModel.PageCommand?
    var onPageSettled: (Int) -> Void
    var onSingleTap: (ComicTapZone) -> Void
    var onLongPress: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComicPagedCollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        let cv = ComicPagedCollectionView(frame: .zero, collectionViewLayout: layout)
        cv.isPagingEnabled = true
        cv.showsHorizontalScrollIndicator = false
        cv.showsVerticalScrollIndicator = false
        cv.backgroundColor = .clear
        cv.contentInsetAdjustmentBehavior = .never
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.register(ComicPagedCell.self, forCellWithReuseIdentifier: ComicPagedCell.reuseId)
        cv.pendingInitialIndex = initialPage
        context.coordinator.collectionView = cv
        context.coordinator.pages = pages
        // Seed the change-detection keys so the first updateUIView doesn't reload.
        context.coordinator.lastLayoutKey = "\(fitMode.rawValue)|\(flipAnim.rawValue)|\(direction.rawValue)|\(loadOriginal)"
        context.coordinator.applyDirection(direction, to: cv)
        return cv
    }

    func updateUIView(_ cv: ComicPagedCollectionView, context: Context) {
        let c = context.coordinator
        c.parent = self

        if c.pages != pages {
            c.pages = pages
            c.zoomedPages.removeAll()
            cv.reloadData()
        }
        c.applyDirection(direction, to: cv)

        // fit-mode / anim / source change → reconfigure visible cells, keeping
        // the current page (reloadData would otherwise reset to page 0).
        let layoutKey = "\(fitMode.rawValue)|\(flipAnim.rawValue)|\(direction.rawValue)|\(loadOriginal)"
        if layoutKey != c.lastLayoutKey {
            c.lastLayoutKey = layoutKey
            let restore = initialPage
            cv.reloadData()
            cv.layoutIfNeeded()
            if cv.numberOfItems(inSection: 0) > restore {
                cv.scrollToItem(at: IndexPath(item: restore, section: 0),
                                at: .centeredHorizontally, animated: false)
            }
        }

        // Programmatic jumps (tap zone / seekbar / thumbnail / bookmark).
        if let cmd = command, cmd.id != c.lastCommandId {
            c.lastCommandId = cmd.id
            if cv.numberOfItems(inSection: 0) > cmd.page {
                cv.scrollToItem(at: IndexPath(item: cmd.page, section: 0),
                                at: .centeredHorizontally, animated: cmd.animated)
            }
        }
        c.updateTransforms()
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {
        var parent: ComicPagedContainer
        var pages: [ComicReaderViewModel.ComicPage] = []
        weak var collectionView: ComicPagedCollectionView?
        var lastCommandId = 0
        var lastLayoutKey = ""
        var zoomedPages = Set<Int>()

        init(_ parent: ComicPagedContainer) { self.parent = parent }

        func applyDirection(_ dir: ComicReaderSettings.PageDirection, to cv: UICollectionView) {
            let mirror = dir == .rtl
            let target: CGAffineTransform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
            if cv.transform != target { cv.transform = target }
        }

        func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { pages.count }

        func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: ComicPagedCell.reuseId, for: indexPath) as! ComicPagedCell
            let page = pages[indexPath.item]
            cell.configure(pageIndex: indexPath.item,
                           url: parent.urlFor(page), preview: parent.previewFor(page),
                           rtl: parent.direction == .rtl,
                           fitMode: parent.fitMode, doubleTapZoom: parent.doubleTapZoom)
            cell.onSingleTap = { [weak self] zone in self?.parent.onSingleTap(zone) }
            cell.onLongPress = { [weak self] idx in self?.parent.onLongPress(idx) }
            cell.onZoomStateChanged = { [weak self] idx, zoomed in
                guard let self, let cv = self.collectionView else { return }
                if zoomed { self.zoomedPages.insert(idx) } else { self.zoomedPages.remove(idx) }
                cv.isScrollEnabled = self.zoomedPages.isEmpty
            }
            return cell
        }

        func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize { cv.bounds.size }

        // MARK: Scroll

        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateTransforms() }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportSettle() }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { reportSettle() }

        private func reportSettle() {
            guard let cv = collectionView, cv.bounds.width > 0 else { return }
            let idx = Int((cv.contentOffset.x / cv.bounds.width).rounded())
                .clampedInt(0, max(pages.count - 1, 0))
            parent.onPageSettled(idx)
        }

        func updateTransforms() {
            guard let cv = collectionView, cv.bounds.width > 0 else { return }
            let animate = parent.flipAnim != .slide && parent.direction == .ltr
            let width = cv.bounds.width
            let centerX = cv.contentOffset.x + width / 2
            for case let cell as ComicPagedCell in cv.visibleCells {
                if !animate { cell.resetFlipTransform(); continue }
                let position = (cell.frame.midX - centerX) / width
                ComicFlipTransformer.apply(parent.flipAnim, to: cell, position: position, width: width)
            }
        }
    }
}

private extension Int {
    func clampedInt(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
