import SwiftUI
import UIKit

// MARK: - Model

/// One playable frame: a single image URL + the work title (with a "(page N)"
/// suffix for multi-page works), matching upstream `SlideshowStore.Session`.
struct SlideshowFrame: Hashable {
    let url: URL
    let title: String
}

/// Identifiable seed so a waterfall long-press can drive a `.fullScreenCover`.
/// Replaces Android's UUID-keyed `SlideshowStore` (no Intent-size limit to work
/// around on iOS — the array travels with the cover).
struct SlideshowSeed: Identifiable {
    let id = UUID()
    let frames: [SlideshowFrame]
    let startFrame: Int
    let random: Bool
}

enum SlideshowBuilder {
    /// Expand a work list into per-page frames (original resolution preferred,
    /// `large` fallback), skipping ugoira — 1:1 with upstream `SlideshowLauncher`.
    /// `startFrame` points at the first page of the tapped work; `random` is true
    /// (upstream always launches shuffled). Returns nil if nothing is playable.
    static func seed(from list: [Illust], tapped: Illust, random: Bool = true) -> SlideshowSeed? {
        var frames: [SlideshowFrame] = []
        var startFrame = 0
        var foundStart = false
        for il in list {
            if il.type == "ugoira" { continue }            // ugoira excluded upstream
            let urls = IllustPages.pages(for: il).compactMap { $0.original ?? $0.large }
            guard !urls.isEmpty else { continue }
            if il.id == tapped.id, !foundStart {
                startFrame = frames.count
                foundStart = true
            }
            let base = il.title?.isEmpty == false ? il.title! : "illust \(il.id)"
            for (i, u) in urls.enumerated() {
                frames.append(SlideshowFrame(url: u, title: urls.count > 1 ? "\(base) (\(i + 1))" : base))
            }
        }
        guard !frames.isEmpty else { return nil }
        if !foundStart { startFrame = 0 }
        return SlideshowSeed(frames: frames, startFrame: startFrame, random: random)
    }
}

// MARK: - Slideshow

/// Fullscreen auto-advancing slideshow — 1:1 with Shaft's `SlideshowFragment`:
/// 6s per image, 0.7s cross-fade, a per-image Ken Burns zoom/pan, looping
/// forever (reshuffling at the end when random). Tap toggles the control bars,
/// which auto-hide after 3s. Keeps the screen awake; immersive (status bar
/// hidden). Storage-free — purely a viewer over the frames handed in.
struct SlideshowView: View {
    let seed: SlideshowSeed
    @Environment(\.dismiss) private var dismiss

    @State private var sequence: [Int]
    @State private var pos: Int
    @State private var isPaused = false
    @State private var showControls = true
    @State private var controlsToken = 0

    init(seed: SlideshowSeed) {
        self.seed = seed
        _sequence = State(initialValue: Self.firstSequence(seed))
        _pos = State(initialValue: 0)
    }

    private var currentFrame: SlideshowFrame? {
        guard sequence.indices.contains(pos) else { return nil }
        let idx = sequence[pos]
        return seed.frames.indices.contains(idx) ? seed.frames[idx] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = currentFrame {
                KenBurnsImage(url: frame.url)
                    .id(pos)                       // new identity per position → cross-fade
                    .transition(.opacity)
                    .ignoresSafeArea()
            }

            controlsOverlay
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(.rect)
        .onTapGesture { toggleControls() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // Auto-advance: the timer restarts whenever the position or pause state
        // changes (manual prev/next reschedules the dwell automatically).
        .task(id: TimerKey(pos: pos, paused: isPaused, count: sequence.count)) {
            guard !isPaused, sequence.count > 1 else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            advance(1)
        }
        // Controls auto-hide 3s after they're shown / last interaction.
        .task(id: controlsToken) {
            guard showControls else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
        // Warm the next two images so cross-fades land instantly.
        .task(id: pos) { preloadAhead() }
    }

    // MARK: Controls

    @ViewBuilder
    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .opacity(showControls ? 1 : 0)
        .allowsHitTesting(showControls)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            iconButton("xmark") { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(pos + 1) / \(sequence.count)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                if let title = currentFrame?.title, !title.isEmpty {
                    Text(title).font(.caption2).lineLimit(1).foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer()
            iconButton(isPaused ? "play.fill" : "pause.fill") { togglePause() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    // Upstream bottom bar is prev/next only — play/pause lives in the top bar.
    private var bottomBar: some View {
        HStack(spacing: 64) {
            iconButton("backward.fill", size: 24) { advance(-1); bumpControls() }
            iconButton("forward.fill", size: 24) { advance(1); bumpControls() }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func iconButton(_ system: String, size: CGFloat = 20, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { bumpControls() }
    }

    private func bumpControls() { controlsToken += 1 }

    private func togglePause() {
        isPaused.toggle()
        bumpControls()
    }

    private func advance(_ delta: Int) {
        guard sequence.count > 1 else { return }
        var next = pos + delta
        if next >= sequence.count {
            if seed.random { sequence = seed.frames.indices.shuffled() }  // reshuffle on loop
            next = 0
        } else if next < 0 {
            next = sequence.count - 1
        }
        withAnimation(.easeInOut(duration: 0.7)) { pos = next }
    }

    private func preloadAhead() {
        for d in 1...2 {
            let p = pos + d
            guard p < sequence.count else { continue }
            let idx = sequence[p]
            guard seed.frames.indices.contains(idx) else { continue }
            let url = seed.frames[idx].url
            Task { _ = await PixivImageCache.shared.load(url) }
        }
    }

    // MARK: Sequence

    /// First pass: tapped frame first, the rest shuffled (random) or in order.
    private static func firstSequence(_ seed: SlideshowSeed) -> [Int] {
        let all = Array(seed.frames.indices)
        guard seed.random else {
            return Array(all[seed.startFrame...]) + Array(all[..<seed.startFrame])
        }
        var rest = all
        rest.removeAll { $0 == seed.startFrame }
        rest.shuffle()
        return [seed.startFrame] + rest
    }

    private struct TimerKey: Equatable { let pos: Int; let paused: Bool; let count: Int }
}

// MARK: - Ken Burns image

/// One slide with a slow zoom + pan (Ken Burns), parametrized randomly per
/// instance so consecutive slides differ — upstream uses 1.08–1.18× over the
/// ~6.7s display+fade window with an ease-in-out curve.
private struct KenBurnsImage: View {
    let url: URL

    // Params live in @State so SwiftUI evaluates `KBParams.make()` once per slide
    // identity (`.id(pos)`) and keeps that value across re-renders. As plain
    // `let`s set in init they'd be re-randomized on every parent body pass (e.g.
    // toggling the control bars), snapping the zoom to a new target mid-slide.
    @State private var params = KBParams.make()
    @State private var animateToEnd = false

    var body: some View {
        GeometryReader { geo in
            PixivAsyncImage(url: url, contentMode: .fill, showsProgress: false)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(animateToEnd ? params.endScale : params.startScale)
                .offset(animateToEnd ? params.endOffset : params.startOffset)
                .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 6.7)) { animateToEnd = true }
        }
    }
}

/// Randomized Ken Burns endpoints — a slow 1.08–1.18× zoom with a pan that stays
/// inside the cropped margin, mirroring upstream's range/curve.
private struct KBParams {
    let startScale: CGFloat
    let endScale: CGFloat
    let startOffset: CGSize
    let endOffset: CGSize

    static func make() -> KBParams {
        let s0 = CGFloat.random(in: 1.08...1.18)
        var s1 = CGFloat.random(in: 1.08...1.18)
        if abs(s1 - s0) < 0.05 { s1 = min(1.18, s0 + 0.08) }  // guarantee visible motion
        func pan(_ scale: CGFloat) -> CGSize {
            let r = (scale - 1) * 90
            return CGSize(width: .random(in: -r...r), height: .random(in: -r...r))
        }
        return KBParams(startScale: s0, endScale: s1, startOffset: pan(s0), endOffset: pan(s1))
    }
}
