import UIKit

// Paged reading container — 1:1 port of upstream `NovelReaderView` + the
// `flip/` animators:
// - drag commit threshold 0.35, commit velocity 1400 px/s, reverse-cancel at
//   0.6× that, settle 320 ms × remaining fraction with a decelerate(1.6) curve
// - tap zones in horizontal thirds (left/center/right, reversible)
// - flip modes: slide / cover (+24pt edge shadow) / simulation (diagonal peel
//   0.12 × width + seam shadow) / none (instant snap at 50%)

// MARK: - Settle animation (DecelerateInterpolator(1.6) equivalent)

private final class ProgressAnimator {
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var onProgress: ((CGFloat) -> Void)?
    private var onFinish: (() -> Void)?

    var isRunning: Bool { displayLink != nil }

    func animate(from: CGFloat, to: CGFloat, baseDurationMs: Double,
                 onProgress: @escaping (CGFloat) -> Void, onFinish: @escaping () -> Void) {
        cancel()
        self.from = from
        self.to = to
        self.onProgress = onProgress
        self.onFinish = onFinish
        duration = baseDurationMs * Double(abs(to - from)) / 1000.0
        if duration <= 0.001 {
            onProgress(to)
            onFinish()
            return
        }
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let t = min(max((CACurrentMediaTime() - startTime) / duration, 0), 1)
        // Android DecelerateInterpolator(factor): y = 1 - (1 - x)^(2 × factor)
        let eased = 1 - pow(1 - t, 3.2)
        let value = from + (to - from) * CGFloat(eased)
        onProgress?(value)
        if t >= 1 {
            let finish = onFinish
            cancel()
            finish?()
        }
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        onProgress = nil
        onFinish = nil
    }
}

// MARK: - Simulation (page curl) overlay

private final class SimulationOverlayView: UIView {
    var currentSnapshot: UIImage?
    var incomingSnapshot: UIImage?
    var progress: CGFloat = 0
    /// +1 forward, -1 backward.
    var direction: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let current = currentSnapshot, let incoming = incomingSnapshot else { return }
        let w = bounds.width
        let h = bounds.height
        let p = min(max(progress, 0), 1)
        let forward = direction > 0

        incoming.draw(in: bounds)

        let offset = w * p
        let peel = w * 0.12 * p
        let tx = forward ? -offset : offset

        ctx.saveGState()
        ctx.translateBy(x: tx, y: 0)
        let path = CGMutablePath()
        if forward {
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: w - peel, y: 0))
            path.addLine(to: CGPoint(x: w, y: peel))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
        } else {
            path.move(to: CGPoint(x: peel, y: 0))
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: peel))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        current.draw(in: bounds)
        ctx.restoreGState()

        // Seam shadow.
        let seamX = forward ? w - offset - w * 0.04 : -offset + w * 0.04 + w
        let shadowWidth = w * 0.06 * (0.3 + p * 0.7)
        let colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.33).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: seamX - shadowWidth, y: 0),
                end: CGPoint(x: seamX + shadowWidth, y: 0),
                options: []
            )
            ctx.restoreGState()
        }
    }
}

// MARK: - Paged container

final class NovelPagedReaderView: UIView, UIGestureRecognizerDelegate {
    // Tunables (exact upstream values).
    private let commitThreshold: CGFloat = 0.35
    private let commitVelocity: CGFloat = 1400
    private let cancelVelocityFactor: CGFloat = 0.6
    private let settleDurationMs: Double = 320
    private let coverShadowWidth: CGFloat = 24

    private let viewA = ReaderPageView()
    private let viewB = ReaderPageView()
    private let viewC = ReaderPageView()
    private var currentView: ReaderPageView
    private var prevView: ReaderPageView
    private var nextView: ReaderPageView
    private let simulationOverlay = SimulationOverlayView()
    private let coverShadow = CAGradientLayer()

    private(set) var pages: [ReaderPage] = []
    private(set) var currentIndex = 0
    private var style: ReaderTypeStyle?
    private var geometry: PageGeometry?
    private var overlays: [HighlightRange] = []

    var flipMode: ReaderFlipMode = .simulation
    var tapZoneReversed = false
    /// One-handed mode: both side zones flip forward; the center still toggles chrome.
    var tapAllForward = false
    var touchLocked = false
    var menuStrings = ReaderMenuStrings() {
        didSet { allViews.forEach { $0.menuStrings = menuStrings } }
    }

    var onPageChanged: ((Int) -> Void)?
    var onTapCenter: (() -> Void)?
    var onEdgeHit: (() -> Void)?
    var onJumpTap: ((Int) -> Void)?
    var onImageTap: ((PageElement.Image) -> Void)?
    var onLinkTap: ((URL) -> Void)?
    var onSelectionAction: ((ReaderSelectionAction, ReaderTextSelection) -> Void)?
    /// TTS 「双击文字切换朗读位置」(#1139). Non-nil arms a double-tap recognizer;
    /// single taps then wait for it to fail (upstream onSingleTapConfirmed).
    var onTextDoubleTap: ((Int) -> Void)?

    /// A drag or settle animation is in flight — TTS auto-follow waits.
    var isUserInteracting: Bool { animator.isRunning || dragDirection != 0 }

    private var allViews: [ReaderPageView] { [viewA, viewB, viewC] }
    private var singleTap: UITapGestureRecognizer?
    private var doubleTap: UITapGestureRecognizer?

    // Drag state.
    private var dragDirection: CGFloat = 0 // +1 forward, -1 backward
    private var dragProgress: CGFloat = 0
    private var incomingView: ReaderPageView?
    private let animator = ProgressAnimator()

    override init(frame: CGRect) {
        currentView = viewA
        prevView = viewB
        nextView = viewC
        super.init(frame: frame)
        for v in allViews {
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.isHidden = true
            addSubview(v)
            wire(v)
        }
        simulationOverlay.frame = bounds
        simulationOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        simulationOverlay.isHidden = true
        addSubview(simulationOverlay)

        coverShadow.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.4).cgColor,
        ]
        coverShadow.startPoint = CGPoint(x: 0, y: 0.5)
        coverShadow.endPoint = CGPoint(x: 1, y: 0.5)
        coverShadow.isHidden = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        singleTap = tap
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        double.delegate = self
        addGestureRecognizer(double)
        doubleTap = double
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func wire(_ v: ReaderPageView) {
        v.onJumpTap = { [weak self] target in self?.onJumpTap?(target) }
        v.onImageTap = { [weak self] img in self?.onImageTap?(img) }
        v.onLinkTap = { [weak self] url in self?.onLinkTap?(url) }
        v.onSelectionAction = { [weak self] action, sel in self?.onSelectionAction?(action, sel) }
    }

    // MARK: Binding

    func bind(pages: [ReaderPage], initialIndex: Int, style: ReaderTypeStyle, geometry: PageGeometry, overlays: [HighlightRange]) {
        animator.cancel()
        self.pages = pages
        self.style = style
        self.geometry = geometry
        self.overlays = overlays
        currentIndex = min(max(initialIndex, 0), max(pages.count - 1, 0))
        backgroundColor = style.theme.backgroundColor
        endDragCleanup()
        rebind()
    }

    func applyOverlays(_ overlays: [HighlightRange]) {
        self.overlays = overlays
        allViews.forEach { $0.applyOverlays(pageOverlays(for: $0.page)) }
    }

    func goTo(index: Int, animated: Bool) {
        guard pages.indices.contains(index), index != currentIndex else { return }
        if !animated || abs(index - currentIndex) != 1 {
            currentIndex = index
            endDragCleanup()
            rebind()
            onPageChanged?(currentIndex)
        } else {
            startFlip(direction: index > currentIndex ? 1 : -1, programmatic: true)
        }
    }

    func flipForward() { startFlip(direction: 1, programmatic: true) }
    func flipBackward() { startFlip(direction: -1, programmatic: true) }

    private func canFlip(_ direction: CGFloat) -> Bool {
        direction > 0 ? currentIndex + 1 < pages.count : currentIndex > 0
    }

    private func pageOverlays(for page: ReaderPage?) -> [HighlightRange] {
        guard let page else { return [] }
        return overlays.filter { $0.absoluteEnd > page.charStart && $0.absoluteStart <= page.charEnd }
    }

    private func rebind() {
        guard let style, let geometry else { return }
        let current = pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
        let prev = pages.indices.contains(currentIndex - 1) ? pages[currentIndex - 1] : nil
        let next = pages.indices.contains(currentIndex + 1) ? pages[currentIndex + 1] : nil
        currentView.bind(page: current, style: style, geometry: geometry, overlays: pageOverlays(for: current))
        prevView.bind(page: prev, style: style, geometry: geometry, overlays: pageOverlays(for: prev))
        nextView.bind(page: next, style: style, geometry: geometry, overlays: pageOverlays(for: next))
        currentView.isHidden = false
        prevView.isHidden = true
        nextView.isHidden = true
        currentView.transform = .identity
        prevView.transform = .identity
        nextView.transform = .identity
        bringSubviewToFront(currentView)
        bringSubviewToFront(simulationOverlay)
    }

    // MARK: Gestures

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if touchLocked { return false }
        if g === doubleTap {
            return onTextDoubleTap != nil && !currentView.hasActiveSelection
                && currentView.absoluteCharIndex(at: g.location(in: currentView)) != nil
        }
        if let pan = g as? UIPanGestureRecognizer {
            if currentView.hasActiveSelection || animator.isRunning { return false }
            let v = pan.velocity(in: self)
            return abs(v.x) > abs(v.y)
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        g === singleTap && other === doubleTap && onTextDoubleTap != nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Jump pills handle their own taps.
        var view: UIView? = touch.view
        while let v = view {
            if v is UIControl { return false }
            view = v.superview
        }
        return true
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard !touchLocked, let index = currentView.absoluteCharIndex(at: g.location(in: currentView)) else { return }
        onTextDoubleTap?(index)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard !touchLocked else { return }
        if currentView.hasActiveSelection {
            currentView.clearSelection()
            return
        }
        let x = g.location(in: self).x
        let third = bounds.width / 3
        if x < third {
            tapZoneReversed || tapAllForward ? flipForward() : flipBackward()
        } else if x > bounds.width - third {
            tapZoneReversed && !tapAllForward ? flipBackward() : flipForward()
        } else {
            onTapCenter?()
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let dx = g.translation(in: self).x
        switch g.state {
        case .began, .changed:
            if dragDirection == 0 {
                guard abs(dx) > 0.5 else { return }
                let direction: CGFloat = dx < 0 ? 1 : -1
                guard canFlip(direction) else {
                    if abs(dx) > 24 { onEdgeHit?() }
                    return
                }
                beginDrag(direction: direction)
            }
            guard dragDirection != 0 else { return }
            dragProgress = min(max((-dx / bounds.width) * dragDirection, 0), 1)
            applyProgress(dragProgress)
        case .ended, .cancelled:
            guard dragDirection != 0 else { return }
            let velocityX = g.velocity(in: self).x
            let commitByProgress = dragProgress >= commitThreshold
            let signedVel = velocityX * -dragDirection
            let commitByVelocity = signedVel >= commitVelocity
            let cancelByVelocity = (velocityX * dragDirection) >= commitVelocity * cancelVelocityFactor
            let commit = (commitByProgress || commitByVelocity) && !cancelByVelocity
            settle(to: commit ? 1 : 0)
        default:
            break
        }
    }

    private func startFlip(direction: CGFloat, programmatic: Bool) {
        guard !animator.isRunning, dragDirection == 0 else { return }
        guard canFlip(direction) else {
            onEdgeHit?()
            return
        }
        beginDrag(direction: direction)
        if flipMode == .none {
            applyProgress(1)
            finishDrag(committed: true)
        } else {
            settle(to: 1)
        }
    }

    private func beginDrag(direction: CGFloat) {
        dragDirection = direction
        dragProgress = 0
        let incoming = direction > 0 ? nextView : prevView
        incomingView = incoming
        incoming.isHidden = false
        switch flipMode {
        case .cover:
            bringSubviewToFront(incoming)
            coverShadow.removeFromSuperlayer()
            coverShadow.frame = CGRect(
                x: direction > 0 ? -coverShadowWidth : incoming.bounds.width,
                y: 0, width: coverShadowWidth, height: incoming.bounds.height
            )
            // Gradient darkens toward the incoming page edge.
            coverShadow.startPoint = direction > 0 ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 1, y: 0.5)
            coverShadow.endPoint = direction > 0 ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0, y: 0.5)
            coverShadow.isHidden = false
            incoming.layer.addSublayer(coverShadow)
            incoming.transform = CGAffineTransform(translationX: bounds.width * dragDirection, y: 0)
        case .slide, .none:
            bringSubviewToFront(currentView)
            bringSubviewToFront(incoming)
            incoming.transform = CGAffineTransform(translationX: bounds.width * dragDirection, y: 0)
        case .simulation:
            simulationOverlay.currentSnapshot = currentView.snapshotImage()
            simulationOverlay.incomingSnapshot = incoming.snapshotImage()
            simulationOverlay.direction = direction
            simulationOverlay.progress = 0
            simulationOverlay.isHidden = false
            bringSubviewToFront(simulationOverlay)
            currentView.isHidden = true
            incoming.isHidden = true
            simulationOverlay.setNeedsDisplay()
        }
    }

    private func applyProgress(_ p: CGFloat) {
        guard let incoming = incomingView else { return }
        let w = bounds.width
        switch flipMode {
        case .slide:
            currentView.transform = CGAffineTransform(translationX: -w * p * dragDirection, y: 0)
            incoming.transform = CGAffineTransform(translationX: w * (1 - p) * dragDirection, y: 0)
        case .cover:
            currentView.transform = .identity
            incoming.transform = CGAffineTransform(translationX: w * (1 - p) * dragDirection, y: 0)
        case .none:
            if p >= 0.5 {
                currentView.transform = CGAffineTransform(translationX: -w * dragDirection, y: 0)
                incoming.transform = .identity
            } else {
                currentView.transform = .identity
                incoming.transform = CGAffineTransform(translationX: w * dragDirection, y: 0)
            }
        case .simulation:
            simulationOverlay.progress = p
            simulationOverlay.setNeedsDisplay()
        }
    }

    private func settle(to: CGFloat) {
        if flipMode == .none {
            applyProgress(to)
            finishDrag(committed: to >= 0.5)
            return
        }
        animator.animate(from: dragProgress, to: to, baseDurationMs: settleDurationMs, onProgress: { [weak self] p in
            self?.dragProgress = p
            self?.applyProgress(p)
        }, onFinish: { [weak self] in
            self?.finishDrag(committed: to >= 0.5)
        })
    }

    private func finishDrag(committed: Bool) {
        if committed, dragDirection != 0 {
            let newIndex = currentIndex + (dragDirection > 0 ? 1 : -1)
            if pages.indices.contains(newIndex) {
                // Swap roles so the bound incoming view becomes current.
                let oldCurrent = currentView
                if dragDirection > 0 {
                    currentView = nextView
                    nextView = prevView
                    prevView = oldCurrent
                } else {
                    currentView = prevView
                    prevView = nextView
                    nextView = oldCurrent
                }
                currentIndex = newIndex
            }
        }
        endDragCleanup()
        rebind()
        if committed { onPageChanged?(currentIndex) }
    }

    private func endDragCleanup() {
        dragDirection = 0
        dragProgress = 0
        incomingView = nil
        simulationOverlay.isHidden = true
        simulationOverlay.currentSnapshot = nil
        simulationOverlay.incomingSnapshot = nil
        coverShadow.isHidden = true
        coverShadow.removeFromSuperlayer()
        allViews.forEach { $0.transform = .identity }
    }
}
