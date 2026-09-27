import SwiftUI
import Photos
import UIKit

/// Full-screen pannable + pinch-zoomable image viewer with multi-page swipe.
/// Save button writes the current page to Photos; for multi-page works a
/// "save all" affordance writes every page in sequence with a count badge.
/// Mirrors Shaft `FragmentImageDetail`.
struct ImageViewerView: View {
    let pages: [IllustPageURLs]
    @Binding var index: Int
    /// Ugoira (#1122): page 0 plays the animation with the same pinch / pan /
    /// double-tap zoom as still pages, and keeps playing while zoomed.
    var ugoiraIllustId: Int64? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var saveStatus: SaveStatus = .idle
    @State private var showControls = true

    enum SaveStatus: Equatable {
        case idle
        case saving
        case savingAll(current: Int, total: Int)
        case saved
        case failed(String)

        var isInFlight: Bool {
            switch self {
            case .saving, .savingAll: return true
            default: return false
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                    Group {
                        if i == 0, let ugoiraIllustId {
                            ZoomableUgoiraPage(illustId: ugoiraIllustId, fallbackURL: page.large ?? page.original) {
                                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                            }
                        } else {
                            ZoomImagePage(large: page.large, original: page.original ?? page.large) {
                                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                            }
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 && showControls ? .always : .never))
            // On the TabView itself, not the pages: the TabView lays its pages
            // out in its own bounds, so a safe-area-constrained TabView gives
            // every page letterboxed (island + home bar) black bands no matter
            // what the pages ignore.
            .ignoresSafeArea()

            HStack(spacing: 12) {
                if pages.count > 1 {
                    Text("\(index + 1) / \(pages.count)")
                        .font(.footnote.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: .capsule)
                        .foregroundStyle(.white)
                }
                Spacer()

                if pages.count > 1 {
                    Button {
                        Task { await saveAll() }
                    } label: {
                        Image(systemName: saveAllButtonIcon)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: .circle)
                    }
                    .disabled(saveStatus.isInFlight)
                }

                Button {
                    Task { await save() }
                } label: {
                    Image(systemName: saveButtonIcon)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: .circle)
                }
                .disabled(saveStatus.isInFlight)

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: .circle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)

            if case .savingAll(let cur, let total) = saveStatus {
                Text("\(cur) / \(total)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.7), in: .capsule)
                    .padding(.top, 60)
                    .padding(.horizontal, 16)
            } else if case .failed(let msg) = saveStatus {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.red.opacity(0.85), in: .rect(cornerRadius: 6))
                    .padding(.top, 60)
                    .padding(.horizontal, 16)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            if AppSettingsStore.shared.illustDetailKeepScreenOn {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var saveButtonIcon: String {
        switch saveStatus {
        case .idle, .failed:               return "square.and.arrow.down"
        case .saving:                      return "ellipsis"
        case .savingAll:                   return "square.and.arrow.down"
        case .saved:                       return "checkmark"
        }
    }

    private var saveAllButtonIcon: String {
        switch saveStatus {
        case .savingAll: return "ellipsis"
        default:         return "square.and.arrow.down.on.square"
        }
    }

    private func save() async {
        // Index straight into `pages` — the same array driving the TabView —
        // so the saved image always matches the visible page.
        guard let page = pages[safe: index], let url = page.original ?? page.large else { return }
        saveStatus = .saving
        if await saveOne(url) {
            saveStatus = .saved
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .saved = saveStatus { saveStatus = .idle }
        }
    }

    private func saveAll() async {
        let total = pages.count
        guard total > 0 else { return }
        guard await PhotoLibrarySaver.requestAuthorization() else {
            saveStatus = .failed("Photos access denied")
            return
        }
        for (i, page) in pages.enumerated() {
            saveStatus = .savingAll(current: i + 1, total: total)
            guard let u = page.original ?? page.large else { continue }
            if !(await saveOne(u, alreadyAuthorized: true)) { return }
        }
        saveStatus = .saved
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if case .saved = saveStatus { saveStatus = .idle }
    }

    /// Returns true on success, sets `saveStatus = .failed(...)` on error.
    /// Writes the original encoded bytes — no re-encode, pixel-identical to
    /// what pixiv serves (same as Shaft's saveImageToGallery).
    private func saveOne(_ url: URL, alreadyAuthorized: Bool = false) async -> Bool {
        guard let data = await PixivImageCache.shared.loadData(url) else {
            saveStatus = .failed("Couldn't load image")
            return false
        }
        if !alreadyAuthorized {
            guard await PhotoLibrarySaver.requestAuthorization() else {
                saveStatus = .failed("Photos access denied")
                return false
            }
        }
        do {
            try await PhotoLibrarySaver.save(data: data)
            return true
        } catch {
            saveStatus = .failed(error.localizedDescription)
            return false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Shared "save image to Photos" helper used by the image viewer and the illust
/// detail download button. Add-only authorization; PNG with JPEG fallback.
enum PhotoLibrarySaver {
    /// Requests add-only Photos access. Returns true if granted (or limited).
    static func requestAuthorization() async -> Bool {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return auth == .authorized || auth == .limited
    }

    /// Writes one image to the Photo library. Throws on failure.
    static func save(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            if let data = image.pngData() ?? image.jpegData(compressionQuality: 0.95) {
                req.addResource(with: .photo, data: data, options: nil)
            }
        }
    }

    /// Writes already-encoded image bytes as-is — lossless save.
    static func save(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}


/// Ugoira page of the viewer (upstream `UgoiraPlayerView` zoom, #1122): pinch to
/// zoom, pan once zoomed (fit-size drags go back to the pager), double tap
/// toggles 1× ↔ 2.5×, single tap toggles the chrome. The play / loading
/// overlays stay pinned to the canvas, not scaled with the picture.
private struct ZoomableUgoiraPage: View {
    let illustId: Int64
    let fallbackURL: URL?
    let onSingleTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private static let maxScale: CGFloat = 4
    private static let doubleTapScale: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            UgoiraView(illustId: illustId, fallbackURL: fallbackURL, contentMode: .fit)
                .allowsHitTesting(false)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(.rect)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(baseScale * value.magnification, 1), Self.maxScale)
                        }
                        .onEnded { _ in
                            baseScale = scale
                            if scale <= 1.01 { reset() } else { clampOffset(geo.size) }
                        }
                )
                // Only claim drags while zoomed; at fit size they belong to the pager.
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(width: baseOffset.width + value.translation.width,
                                            height: baseOffset.height + value.translation.height)
                        }
                        .onEnded { _ in
                            guard scale > 1 else { return }
                            clampOffset(geo.size)
                        },
                    including: scale > 1 ? .all : .subviews
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if scale > 1 { reset() } else { scale = Self.doubleTapScale; baseScale = scale }
                    }
                }
                .onTapGesture(count: 1, perform: onSingleTap)
        }
    }

    private func reset() {
        scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
    }

    /// Keep the zoomed picture covering the canvas edges it can reach.
    private func clampOffset(_ size: CGSize) {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        withAnimation(.easeOut(duration: 0.2)) {
            offset = CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
        }
        baseOffset = offset
    }
}
