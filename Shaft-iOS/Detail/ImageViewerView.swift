import SwiftUI
import Photos

/// Full-screen pannable + pinch-zoomable image viewer with multi-page swipe.
/// Save button writes the current page to Photos; for multi-page works a
/// "save all" affordance writes every page in sequence with a count badge.
/// Mirrors Shaft `FragmentImageDetail`.
struct ImageViewerView: View {
    let urls: [URL]
    @Binding var index: Int

    @Environment(\.dismiss) private var dismiss
    @State private var saveStatus: SaveStatus = .idle

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
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    ZoomableAsyncImage(url: url)
                        .tag(i)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))

            HStack(spacing: 12) {
                if urls.count > 1 {
                    Text("\(index + 1) / \(urls.count)")
                        .font(.footnote.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: .capsule)
                        .foregroundStyle(.white)
                }
                Spacer()

                if urls.count > 1 {
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
        guard let url = urls[safe: index] else { return }
        saveStatus = .saving
        if await saveOne(url) {
            saveStatus = .saved
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .saved = saveStatus { saveStatus = .idle }
        }
    }

    private func saveAll() async {
        let total = urls.count
        guard total > 0 else { return }
        guard await PhotoLibrarySaver.requestAuthorization() else {
            saveStatus = .failed("Photos access denied")
            return
        }
        for (i, u) in urls.enumerated() {
            saveStatus = .savingAll(current: i + 1, total: total)
            if !(await saveOne(u, alreadyAuthorized: true)) { return }
        }
        saveStatus = .saved
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if case .saved = saveStatus { saveStatus = .idle }
    }

    /// Returns true on success, sets `saveStatus = .failed(...)` on error.
    private func saveOne(_ url: URL, alreadyAuthorized: Bool = false) async -> Bool {
        guard let image = await PixivImageCache.shared.load(url) else {
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
            try await PhotoLibrarySaver.save(image)
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
}

/// One-page pinch + double-tap zoom. Uses ScrollView's built-in zoom for
/// simplicity (iOS 17+ accepts `.zoomable()` style via gesture composition).
struct ZoomableAsyncImage: View {
    let url: URL?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            PixivAsyncImage(url: url, contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(zoomGesture)
                .simultaneousGesture(panGesture)
                .onTapGesture(count: 2) { toggleZoom() }
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                scale = max(1, min(lastScale * v.magnification, 5))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.3)) {
                        scale = 1; lastScale = 1
                        offset = .zero; lastOffset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + v.translation.width,
                    height: lastOffset.height + v.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3)) {
            if scale > 1 {
                scale = 1; lastScale = 1
                offset = .zero; lastOffset = .zero
            } else {
                scale = 2.5; lastScale = 2.5
            }
        }
    }
}
