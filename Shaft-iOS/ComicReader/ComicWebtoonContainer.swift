import SwiftUI
import UIKit

// Vertical continuous viewport (条漫 / webtoon) — the iOS analog of upstream
// `WebtoonViewport` (a vertical RecyclerView). Pages stack top-to-bottom, each
// fit to the screen width; a single tap toggles chrome. Cell heights are driven
// by each page's aspect ratio, cached as it decodes (default estimate until
// known, so off-screen pages below resize without disturbing the viewport).

private final class ComicWebtoonCell: UICollectionViewCell {
    static let reuseId = "ComicWebtoonCell"

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let reloadButton = UIButton(type: .system)
    private var loadTask: Task<Void, Never>?
    private var index = 0
    private var url: URL?
    private var preview: URL?

    var onAspectKnown: ((Int, CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        reloadButton.setImage(UIImage(systemName: "arrow.clockwise",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)), for: .normal)
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
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(index: Int, url: URL?, preview: URL?) {
        self.index = index
        self.url = url
        self.preview = preview
        reloadButton.isHidden = true
        imageView.image = (url.flatMap { PixivImageCache.shared.image(for: $0) })
            ?? (preview.flatMap { PixivImageCache.shared.image(for: $0) })
        if imageView.image == nil { spinner.startAnimating() }
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        guard let url else { showError(); return }
        if let img = await PixivImageCache.shared.load(url) {
            if Task.isCancelled { return }
            imageView.image = img
            spinner.stopAnimating()
            reloadButton.isHidden = true
            if img.size.width > 0 {
                onAspectKnown?(index, img.size.height / img.size.width)
            }
        } else if !Task.isCancelled {
            showError()
        }
    }

    private func showError() {
        spinner.stopAnimating()
        reloadButton.isHidden = false
    }

    @objc private func reloadTapped() {
        reloadButton.isHidden = true
        spinner.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        reloadButton.isHidden = true
        spinner.stopAnimating()
    }
}

final class ComicWebtoonCollectionView: UICollectionView {
    var pendingInitialIndex: Int?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        let widthChanged = bounds.width != lastWidth
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if widthChanged { lastWidth = bounds.width; collectionViewLayout.invalidateLayout() }
        if let idx = pendingInitialIndex, numberOfItems(inSection: 0) > idx {
            pendingInitialIndex = nil
            layoutIfNeeded()
            scrollToItem(at: IndexPath(item: idx, section: 0), at: .top, animated: false)
        }
    }
}

struct ComicWebtoonContainer: UIViewRepresentable {
    let pages: [ComicReaderViewModel.ComicPage]
    let urlFor: (ComicReaderViewModel.ComicPage) -> URL?
    let previewFor: (ComicReaderViewModel.ComicPage) -> URL?
    let loadOriginal: Bool
    let initialPage: Int
    let command: ComicReaderViewModel.PageCommand?
    var onVisiblePage: (Int) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComicWebtoonCollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        let cv = ComicWebtoonCollectionView(frame: .zero, collectionViewLayout: layout)
        cv.showsVerticalScrollIndicator = false
        cv.backgroundColor = .clear
        cv.contentInsetAdjustmentBehavior = .never
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.register(ComicWebtoonCell.self, forCellWithReuseIdentifier: ComicWebtoonCell.reuseId)
        cv.pendingInitialIndex = initialPage
        context.coordinator.collectionView = cv
        context.coordinator.pages = pages
        context.coordinator.lastLoadOriginal = loadOriginal

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        cv.addGestureRecognizer(tap)
        return cv
    }

    func updateUIView(_ cv: ComicWebtoonCollectionView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.pages != pages || c.lastLoadOriginal != loadOriginal {
            let restore = initialPage
            c.pages = pages
            c.lastLoadOriginal = loadOriginal
            c.aspect.removeAll()
            cv.reloadData()
            cv.layoutIfNeeded()
            if cv.numberOfItems(inSection: 0) > restore {
                cv.scrollToItem(at: IndexPath(item: restore, section: 0), at: .top, animated: false)
            }
        }
        if let cmd = command, cmd.id != c.lastCommandId {
            c.lastCommandId = cmd.id
            if cv.numberOfItems(inSection: 0) > cmd.page {
                cv.scrollToItem(at: IndexPath(item: cmd.page, section: 0), at: .top, animated: cmd.animated)
            }
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {
        var parent: ComicWebtoonContainer
        var pages: [ComicReaderViewModel.ComicPage] = []
        weak var collectionView: ComicWebtoonCollectionView?
        var aspect = [Int: CGFloat]()
        var lastCommandId = 0
        var lastLoadOriginal = true
        private var lastVisible = -1

        init(_ parent: ComicWebtoonContainer) { self.parent = parent }

        @objc func handleTap() { parent.onTap() }

        func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { pages.count }

        func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: ComicWebtoonCell.reuseId, for: indexPath) as! ComicWebtoonCell
            let page = pages[indexPath.item]
            cell.configure(index: indexPath.item, url: parent.urlFor(page), preview: parent.previewFor(page))
            cell.onAspectKnown = { [weak self] idx, ratio in
                guard let self else { return }
                let prev = self.aspect[idx]
                guard prev == nil || abs((prev ?? 0) - ratio) > 0.01 else { return }
                self.aspect[idx] = ratio
                // Resize just this item; pages above keep their measured heights.
                guard let cv = self.collectionView else { return }
                let ctx = UICollectionViewFlowLayoutInvalidationContext()
                ctx.invalidateItems(at: [IndexPath(item: idx, section: 0)])
                cv.collectionViewLayout.invalidateLayout(with: ctx)
            }
            return cell
        }

        func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            let w = cv.bounds.width
            let ratio = aspect[indexPath.item] ?? 1.4   // estimate before the page decodes
            return CGSize(width: w, height: max(1, w * ratio))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView else { return }
            let topPoint = CGPoint(x: cv.bounds.midX, y: cv.contentOffset.y + 1)
            guard let ip = cv.indexPathForItem(at: topPoint) else { return }
            if ip.item != lastVisible {
                lastVisible = ip.item
                parent.onVisiblePage(ip.item)
            }
        }
    }
}
