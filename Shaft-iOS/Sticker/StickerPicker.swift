import SwiftUI

@MainActor final class StickerPickerPosition {
    var generation: String?
    var category = 0
    var offsets: [CGFloat] = [0, 0, 0]
}

struct StickerPicker: View {
    var inline = false
    var primary: Color = Theme.brand
    var position: StickerPickerPosition?
    var repository: StickerRepository = .shared
    var preparesResources = true
    var onPick: (Sticker) -> Void
    @State private var ownPosition = StickerPickerPosition()
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        StickerPickerHost(state: repository.state, inline: inline, primary: UIColor(primary),
                          copy: StickerCopy(tag: language.activeTag), position: position ?? ownPosition,
                          animate: !reduceMotion && scenePhase == .active, typeSize: typeSize,
                          retry: { repository.prepare() }, close: { dismiss() }, pick: { sticker, generation in
            guard repository.state.ready?.generation == generation else { return }
            onPick(sticker)
        }, failure: { error, generation in repository.localFailure(error, generation: generation) })
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(Theme.v3MenuBg)
        .ignoresSafeArea(.container, edges: inline ? [] : .bottom)
        .task { if preparesResources { repository.prepare() } }
        .accessibilityIdentifier("sticker-picker")
    }
}

private struct StickerPickerHost: UIViewControllerRepresentable {
    let state: StickerState
    let inline: Bool
    let primary: UIColor
    let copy: StickerCopy
    let position: StickerPickerPosition
    let animate: Bool
    let typeSize: DynamicTypeSize
    let retry: () -> Void
    let close: () -> Void
    let pick: (Sticker, String) -> Void
    let failure: (Error, String) -> Void
    func makeUIViewController(context: Context) -> StickerPickerController { StickerPickerController() }
    func updateUIViewController(_ controller: StickerPickerController, context: Context) {
        controller.update(self)
    }
}

private final class StickerPickerController: UIViewController, UIScrollViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private var config: StickerPickerHost?
    private var ready: StickerReady?
    private let header = UIView(), tabScroll = UIScrollView(), track = UIView(), indicator = UIView()
    private let pager = UIScrollView(), close = UIButton(type: .system)
    private let loading = UIStackView(), spinner = UIActivityIndicatorView(style: .medium), status = UILabel(), retry = UIButton(type: .system)
    private var tabs: [UIButton] = [], grids: [UICollectionView] = []
    private var fraction: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var restoring = false
    private var fontScale: CGFloat = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Theme.v3MenuBg)
        view.addSubview(header); header.addSubview(tabScroll); header.addSubview(close)
        tabScroll.showsHorizontalScrollIndicator = false
        tabScroll.addSubview(track); track.addSubview(indicator)
        track.backgroundColor = UIColor(Theme.v3Surface2); track.layer.cornerRadius = 14
        track.accessibilityIdentifier = "sticker-tab-track"
        indicator.accessibilityIdentifier = "sticker-tab-indicator"
        indicator.layer.cornerRadius = 11
        for index in 0..<3 {
            let button = UIButton(type: .custom)
            button.tag = index; button.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "sticker-tab-\(StickerCategory.allCases[index].rawValue)"
            tabs.append(button); tabScroll.addSubview(button)
        }
        close.addTarget(self, action: #selector(dismissPicker), for: .touchUpInside)
        close.accessibilityIdentifier = "sticker-close"
        pager.isPagingEnabled = true; pager.showsHorizontalScrollIndicator = false
        pager.delegate = self; pager.contentInsetAdjustmentBehavior = .never
        view.addSubview(pager)
        for index in 0..<3 {
            let layout = UICollectionViewFlowLayout(); layout.minimumLineSpacing = 0; layout.minimumInteritemSpacing = 0
            let grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
            grid.tag = index; grid.dataSource = self; grid.delegate = self
            grid.backgroundColor = .clear; grid.alwaysBounceVertical = true
            grid.contentInsetAdjustmentBehavior = .never
            grid.register(StickerCell.self, forCellWithReuseIdentifier: "sticker")
            grid.isPrefetchingEnabled = false
            grid.accessibilityIdentifier = "sticker-grid-\(StickerCategory.allCases[index].rawValue)"
            grids.append(grid); pager.addSubview(grid)
        }
        loading.axis = .vertical; loading.alignment = .center; loading.spacing = 16
        loading.addArrangedSubview(spinner); loading.addArrangedSubview(status); loading.addArrangedSubview(retry)
        status.numberOfLines = 0; status.textAlignment = .center; status.textColor = UIColor(Theme.v3Text2)
        status.accessibilityIdentifier = "sticker-status"
        retry.addTarget(self, action: #selector(retryLoading), for: .touchUpInside)
        retry.accessibilityIdentifier = "sticker-retry"
        view.addSubview(loading)
    }

    func update(_ configuration: StickerPickerHost) {
        loadViewIfNeeded()
        config = configuration
        // Match sp scaling while retaining the native touch dimensions.
        let sizes: [DynamicTypeSize: CGFloat] = [.xSmall: 0.82, .small: 0.88, .medium: 0.94, .large: 1,
            .xLarge: 1.12, .xxLarge: 1.23, .xxxLarge: 1.35, .accessibility1: 1.64,
            .accessibility2: 1.95, .accessibility3: 2.35, .accessibility4: 2.76, .accessibility5: 3.12]
        fontScale = sizes[configuration.typeSize] ?? 1
        for (index, tab) in tabs.enumerated() {
            tab.setTitle(configuration.copy.text(StickerCategory.allCases[index].rawValue), for: .normal)
            tab.titleLabel?.font = UIFont(name: "Montserrat-Medium", size: 13 * fontScale) ?? .systemFont(ofSize: 13 * fontScale, weight: .medium)
        }
        close.isHidden = configuration.inline
        close.setTitle(configuration.copy.text("close"), for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 16 * fontScale)
        close.tintColor = readableAccent(configuration.primary)
        indicator.backgroundColor = configuration.primary
        status.font = UIFont(name: "Montserrat-Regular", size: 15 * fontScale) ?? .systemFont(ofSize: 15 * fontScale)
        var retryStyle = UIButton.Configuration.filled()
        retryStyle.title = configuration.copy.text("retry"); retryStyle.cornerStyle = .capsule
        retryStyle.baseBackgroundColor = configuration.primary; retryStyle.baseForegroundColor = ink(configuration.primary)
        retryStyle.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        retry.configuration = retryStyle
        if let value = configuration.state.ready {
            if ready?.generation != value.generation {
                ready = value
                let position = configuration.position
                if position.generation != value.generation { position.generation = value.generation; position.category = 0; position.offsets = [0, 0, 0] }
                fraction = CGFloat(position.category); lastWidth = 0
                grids.forEach { $0.reloadData() }
            }
            pager.isHidden = false; tabScroll.isHidden = false; loading.isHidden = true
        } else {
            ready = nil; grids.forEach { $0.visibleCells.forEach { ($0 as? StickerCell)?.image.clear() } }
            pager.isHidden = true; tabScroll.isHidden = true; loading.isHidden = false
            retry.isHidden = true; spinner.startAnimating()
            switch configuration.state {
            case .downloading(let bytes, let total): status.text = configuration.copy.format("downloading", String(total > 0 ? bytes * 100 / total : 0))
            case .extracting: status.text = configuration.copy.text("extracting")
            case .failed(let error):
                status.text = configuration.copy.format("failed", error.localizedDescription)
                spinner.stopAnimating(); retry.isHidden = false
            default: status.text = configuration.copy.text("checking")
            }
        }
        view.setNeedsLayout()
        refreshVisibleCells()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let config else { return }
        let w = view.bounds.width
        let tabHeight = max(48, 13 * fontScale * 1.4 + 12)
        var rowHeight = max(config.inline ? 48 : 56, tabHeight)
        let widths = tabs.map { max(64, ceil($0.titleLabel?.intrinsicContentSize.width ?? 0) + 32) }
        let closeWidth = config.inline ? 0 : min(w * 0.42, close.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: rowHeight)).width + 40)
        // At very large text sizes, give a long category its own full-width row.
        // Normal-size phone/tablet layouts retain Android's single 56pt header.
        let stacked = !config.inline && (widths.max() ?? 0) > w - 20 - closeWidth
        if stacked { rowHeight += tabHeight }
        header.frame = CGRect(x: 0, y: 0, width: w, height: rowHeight)
        close.frame = CGRect(x: w - closeWidth, y: 0, width: closeWidth, height: stacked ? rowHeight - tabHeight : rowHeight)
        tabScroll.frame = CGRect(x: 20, y: stacked ? rowHeight - tabHeight : (rowHeight - tabHeight) / 2,
                                width: max(0, w - 20 - (stacked ? 20 : closeWidth)), height: tabHeight)
        var x: CGFloat = 3
        for (index, tab) in tabs.enumerated() {
            let width = widths[index]
            tab.frame = CGRect(x: x, y: 0, width: width, height: tabHeight); x += width
        }
        track.frame = CGRect(x: 0, y: 3, width: x + 3, height: tabHeight - 6)
        tabScroll.contentSize = CGSize(width: x + 3, height: tabHeight)
        pager.frame = CGRect(x: 0, y: rowHeight, width: w, height: max(0, view.bounds.height - rowHeight))
        restoring = true
        pager.contentSize = CGSize(width: w * 3, height: pager.bounds.height)
        for (index, grid) in grids.enumerated() {
            let next = CGRect(x: CGFloat(index) * w, y: 0, width: w, height: pager.bounds.height)
            if grid.frame != next { grid.frame = next; grid.collectionViewLayout.invalidateLayout() }
            grid.contentInset = UIEdgeInsets(top: 12, left: 12, bottom: 8 + (config.inline ? 0 : view.safeAreaInsets.bottom), right: 12)
            grid.verticalScrollIndicatorInsets.bottom = grid.contentInset.bottom
        }
        if lastWidth != w {
            pager.contentOffset.x = CGFloat(config.position.category) * w
            fraction = CGFloat(config.position.category)
            for (index, grid) in grids.enumerated() {
                grid.layoutIfNeeded()
                let maximum = max(-12, grid.contentSize.height - grid.bounds.height + grid.contentInset.bottom)
                grid.contentOffset.y = min(maximum, max(-12, config.position.offsets[index] - 12))
            }
            lastWidth = w
        }
        restoring = false
        let fit = loading.systemLayoutSizeFitting(CGSize(width: max(0, w - 48), height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        loading.frame = CGRect(x: 24, y: rowHeight + max(0, (pager.bounds.height - fit.height) / 2), width: max(0, w - 48), height: fit.height)
        updateIndicator(); refreshVisibleCells()
    }

    private func updateIndicator() {
        guard let config, !tabs.isEmpty else { return }
        let start = min(2, max(0, Int(fraction))), end = min(2, start + 1), t = fraction - CGFloat(start)
        let from = tabs[start].frame, to = tabs[end].frame
        indicator.frame = CGRect(x: from.minX + (to.minX - from.minX) * t, y: 3,
                                 width: from.width + (to.width - from.width) * t, height: max(36, track.bounds.height - 6))
        for (index, tab) in tabs.enumerated() {
            tab.isSelected = index == config.position.category
            tab.accessibilityTraits = tab.isSelected ? [.button, .selected] : .button
            tab.setTitleColor(blend(UIColor(Theme.v3Text1), ink(config.primary), fraction: max(0, 1 - abs(CGFloat(index) - fraction))), for: .normal)
        }
        tabScroll.contentOffset.x = max(0, min(tabScroll.contentSize.width - tabScroll.bounds.width, indicator.frame.midX - tabScroll.bounds.width / 2))
    }
    @objc private func selectTab(_ button: UIButton) {
        guard let config, config.position.category != button.tag else { return }
        config.position.category = button.tag
        pager.setContentOffset(CGPoint(x: CGFloat(button.tag) * pager.bounds.width, y: 0), animated: config.animate)
        if !config.animate { fraction = CGFloat(button.tag); updateIndicator() }
    }
    @objc private func dismissPicker() { config?.close() }
    @objc private func retryLoading() { config?.retry() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !restoring, let config else { return }
        if scrollView === pager, pager.bounds.width > 0 {
            fraction = max(0, min(2, pager.contentOffset.x / pager.bounds.width))
            config.position.category = Int(fraction.rounded())
            updateIndicator(); refreshVisibleCells()
        } else if let grid = scrollView as? UICollectionView {
            config.position.offsets[grid.tag] = grid.contentOffset.y + 12
        }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { ready?.items[collectionView.tag].count ?? 0 }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "sticker", for: indexPath) as! StickerCell
        bind(cell, grid: collectionView, index: indexPath.item)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? StickerCell)?.image.clear() }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let ready else { return }
        config?.pick(ready.items[collectionView.tag][indexPath.item], ready.generation)
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let available = max(48, collectionView.bounds.width - 24)
        let columns = max(3, min(12, Int(available / 48)))
        return CGSize(width: floor(available / CGFloat(columns) * UIScreen.main.scale) / UIScreen.main.scale, height: 48)
    }
    private func bind(_ cell: StickerCell, grid: UICollectionView, index: Int) {
        guard let ready, let config else { cell.image.clear(); return }
        let sticker = ready.items[grid.tag][index]
        cell.accessibilityLabel = sticker.name
        cell.accessibilityIdentifier = "sticker-\(sticker.id)"
        if abs(CGFloat(grid.tag) - fraction) < 1 {
            cell.image.configure(ready: ready, id: sticker.id, size: 64, animate: config.animate, failure: config.failure)
        } else { cell.image.clear() }
    }
    private func refreshVisibleCells() {
        for grid in grids { for cell in grid.visibleCells {
            if let cell = cell as? StickerCell, let index = grid.indexPath(for: cell)?.item { bind(cell, grid: grid, index: index) }
        } }
    }
    private func ink(_ color: UIColor) -> UIColor {
        // V3Palette.onPrimary: keep white on the normal theme fills, darken
        // the same hue for bright yellow/green fills instead of using dark-mode ink.
        luminance(color) < 0.5 ? .white : withLightness(color, min(lightness(color), 0.25))
    }
    private func readableAccent(_ color: UIColor) -> UIColor {
        let background = UIColor(Theme.v3MenuBg).resolvedColor(with: traitCollection)
        let dark = traitCollection.userInterfaceStyle == .dark
        let base = dark ? max(lightness(color), 0.6) : min(lightness(color), 0.4)
        for step in 0...40 {
            let candidate = withLightness(color, max(0, min(1, base + CGFloat(step) * (dark ? 0.02 : -0.02))))
            let a = luminance(candidate), b = luminance(background)
            if (max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5 { return candidate }
        }
        return dark ? .white : .black
    }
    private func lightness(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (max(r, g, b) + min(r, g, b)) / 2
    }
    private func withLightness(_ color: UIColor, _ target: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let old = lightness(color), denominator = 1 - abs(2 * old - 1)
        let ratio = denominator > 0 ? (1 - abs(2 * target - 1)) / denominator : 0
        return UIColor(red: (r - old) * ratio + target, green: (g - old) * ratio + target,
                       blue: (b - old) * ratio + target, alpha: a)
    }
    private func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    private func blend(_ a: UIColor, _ b: UIColor, fraction: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.resolvedColor(with: traitCollection).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.resolvedColor(with: traitCollection).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * fraction, green: ag + (bg - ag) * fraction,
                       blue: ab + (bb - ab) * fraction, alpha: aa + (ba - aa) * fraction)
    }
}

private final class StickerCell: UICollectionViewCell {
    let image = StickerBitmapView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(image); isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); image.frame = contentView.bounds.insetBy(dx: 8, dy: 8) }
    override func prepareForReuse() { super.prepareForReuse(); image.clear() }
    override var isHighlighted: Bool { didSet {
        contentView.alpha = isHighlighted ? 0.6 : 1
        contentView.transform = isHighlighted && !UIAccessibility.isReduceMotionEnabled ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
    } }
}
