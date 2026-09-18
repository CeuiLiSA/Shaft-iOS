import SwiftUI
import ImageIO

struct PlazaPostView: View {
    let post: PlazaPost
    let store: PlazaStore
    var detail = false
    var comment = false
    var onReply: (() -> Void)?
    @Environment(OnboardingStore.self) private var language
    @State private var showReactions = false
    private var copy: PlazaCopy { .init(tag: language.activeTag) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if comment {
                HStack(alignment: .top, spacing: 8) {
                    avatar(size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        PlazaText(value: post.displayName, size: 14, weight: 600)
                        content
                    }
                }
            } else {
                HStack(spacing: 12) {
                    avatar(size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        PlazaText(value: post.displayName, size: 15, weight: 600).lineLimit(2)
                        PlazaText(value: post.date.formatted(.dateTime.year().month().day().locale(language.currentLocale)), size: 12, weight: 500, color: Theme.v3Text3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !detail { PlazaPostMenu(post: post, store: store).padding(.trailing, -12) }
                }
                content
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, detail ? 8 : comment ? 12 : 14)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .modifier(PlazaCommentMenu(post: post, store: store, enabled: comment))
        .sheet(isPresented: $showReactions) {
            PlazaStickerPicker { sticker in
                showReactions = false
                Task {
                    let reaction = post.reactions?.first { $0.stickerId == sticker.id }
                        ?? PlazaReaction(emoji: "sticker:\(sticker.id)", count: 0, selected: false, stickerId: sticker.id)
                    await store.react(post, reaction)
                }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = post.title, !title.isEmpty {
                PlazaText(value: title, size: detail ? 24 : 16, weight: detail ? 700 : 600, lineHeight: detail ? 31.2 : 22.4)
                    .lineLimit(detail ? nil : 2)
                    .padding(.top, comment ? 8 : detail ? 16 : 12)
            }
            if !post.text.isEmpty {
                PlazaText(value: post.text, size: detail ? 16 : 15, color: detail ? Theme.v3Text1 : Theme.v3Text2, lineHeight: detail ? 27.2 : 24)
                    .lineLimit(detail || comment ? nil : 3)
                    .textSelection(.enabled)
                    .padding(.top, comment ? 0 : (post.title?.isEmpty != false ? 12 : 6))
            }
            if !post.images.isEmpty || !post.linkedPages.isEmpty {
                PlazaImageGrid(post: post, store: store, detail: detail).padding(.top, detail ? 16 : 12)
            }
            if let id = post.objectId {
                NavigationLink(value: objectRoute(id)) {
                    HStack(spacing: 4) {
                        PlazaText(value: copy.format("reference_label", copy.text("object_\(post.objectType ?? "illust")"), String(id)), size: 13, weight: 600, color: PlazaPalette.accent)
                        PlazaIcon(glyph: .chevron, size: 16)
                    }.padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 8)
                        .frame(minHeight: 40).foregroundStyle(PlazaPalette.accent)
                        .background(PlazaPalette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(PlazaPalette.primary.opacity(0.15), lineWidth: 0.5) }
                }.buttonStyle(PlazaPressStyle()).padding(.top, detail ? 16 : 12)
            }
            reactions.padding(.top, detail || comment ? 12 : 8)
            if !detail, let previews = post.commentsPreview, !previews.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(previews) { preview in
                        HStack(spacing: 6) {
                            PlazaText(value: copy.format("preview_author", preview.displayName), size: 14).fixedSize()
                            PlazaText(value: preview.text, size: 14, color: Theme.v3Text2).lineLimit(1)
                        }
                    }
                    if post.replyCount > previews.count {
                        PlazaText(value: copy.format("reply_count", String(post.replyCount)), size: 12, weight: 600, color: PlazaPalette.accent).frame(minHeight: 32)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(comment ? 0 : 12)
                    .background(comment ? Color.clear : PlazaPalette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .background(comment ? Color.clear : PlazaPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 12)
            }
            if comment {
                Button { onReply?() } label: {
                    PlazaText(value: copy.format("reply_time", relativeDate), size: 12, weight: 500, color: Theme.v3Text3)
                }.buttonStyle(.plain).padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reactions: some View {
        PlazaReactionLayout {
            PlazaPill(glyph: post.liked ? .heartFilled : .heart, count: post.likeCount, selected: post.liked,
                      label: copy.text(post.liked ? "unlike" : "like")) { Task { await store.like(post) } }
                .accessibilityIdentifier("plaza-like-\(post.id)")
            ForEach(post.reactions ?? []) { reaction in
                if let id = reaction.stickerId {
                    Button { Task { await store.react(post, reaction) } } label: {
                        HStack(spacing: 6) {
                            PlazaStickerImage(id: id).frame(width: 18, height: 18)
                            PlazaText(value: String(reaction.count), weight: 600, color: reaction.selected ? PlazaPalette.accent : Theme.v3Text2)
                        }.padding(.horizontal, 12).frame(minHeight: 32)
                            .background(PlazaPalette.primary.opacity(reaction.selected ? 0.20 : 0.08), in: Capsule())
                            .overlay { Capsule().strokeBorder(PlazaPalette.primary.opacity(reaction.selected ? 0.3 : 0), lineWidth: 0.5) }
                            .frame(minHeight: 48)
                    }.buttonStyle(PlazaPressStyle()).accessibilityLabel(copy.text("react_post"))
                } else {
                    PlazaPill(emoji: reaction.emoji, count: reaction.count, selected: reaction.selected,
                              label: copy.format("react_emoji", reaction.emoji)) { Task { await store.react(post, reaction) } }
                }
            }
            PlazaPill(glyph: .emoji, label: copy.text("add_reaction")) { showReactions = true }
            PlazaPill(glyph: .comment, count: detail ? nil : post.replyCount, label: copy.text("reply_post")) { onReply?() }
        }.disabled(store.busy)
    }
    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.currentLocale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: post.date, relativeTo: Date())
    }
    private func avatar(size: CGFloat) -> some View {
        NavigationLink(value: AppRoute.userProfile(post.uid)) {
            ZStack {
                Circle().fill(PlazaPalette.primary.opacity(0.12))
                if let url = post.avatarUrl.flatMap(URL.init(string:)) {
                    if url.host?.hasSuffix(".pximg.net") == true {
                        PixivAsyncImage(url: url, showsProgress: false, placeholder: .clear)
                    } else { PlazaRemoteImage(url: url, pixels: 144) }
                } else { PlazaText(value: String(post.displayName.prefix(1)), size: size / 2, weight: 600, color: PlazaPalette.accent) }
            }.frame(width: size, height: size).clipShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(copy.format("view_profile", post.displayName))
    }
    private func objectRoute(_ id: Int64) -> AppRoute {
        switch post.objectType {
        case "novel": return .novelDetail(id)
        case "user": return .userProfile(id)
        default: return .illustDetail(id)
        }
    }
}

struct PlazaPostMenu: View {
    let post: PlazaPost
    let store: PlazaStore
    var color: Color = Theme.v3Text3
    var body: some View {
        PlazaPostActions(post: post, store: store, content: PlazaIcon(glyph: .more)
            .foregroundStyle(color).frame(width: 48, height: 48).contentShape(Rectangle()))
    }
}

private struct PlazaCommentMenu: ViewModifier {
    let post: PlazaPost
    let store: PlazaStore
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { PlazaPostActions(post: post, store: store, contextual: true, content: content) }
        else { content }
    }
}

private struct PlazaPostActions<Content: View>: View {
    let post: PlazaPost
    let store: PlazaStore
    var contextual = false
    let content: Content
    @Environment(OnboardingStore.self) private var language
    @State private var deleting = false
    @State private var blocking = false
    @State private var reporting = false
    private var copy: PlazaCopy { .init(tag: language.activeTag) }
    var body: some View {
        Group {
            if contextual { content.contextMenu { actions } }
            else { Menu { actions } label: { content }.accessibilityLabel(copy.text("more_menu")) }
        }
        .disabled(store.busy)
        .confirmationDialog(copy.text("delete_confirm"), isPresented: $deleting, titleVisibility: .visible) {
            Button(copy.text("delete_confirm_yes"), role: .destructive) { Task { await store.delete(post) } }
            Button(copy.text("cancel"), role: .cancel) {}
        }
        .confirmationDialog(copy.text("block_notice"), isPresented: $blocking, titleVisibility: .visible) {
            Button(copy.text("block_user"), role: .destructive) { Task { await store.block(post.uid, selected: true) } }
            Button(copy.text("cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $reporting) { PlazaReportView(post: post, store: store) }
    }
    @ViewBuilder private var actions: some View {
            ShareLink(item: [post.title ?? "", post.text].filter { !$0.isEmpty }.joined(separator: "\n\n")) { Text(copy.text("share_text")) }
            NavigationLink(value: AppRoute.userProfile(post.uid)) { Text(copy.text("view_author")) }
            if post.uid == store.uid {
                Button(copy.text("delete_post"), role: .destructive) { deleting = true }
            } else {
                Button(copy.text("report_title")) { reporting = true }
                Button(copy.text("block_user"), role: .destructive) { blocking = true }
            }
    }
}

struct PlazaImageGrid: View {
    let post: PlazaPost
    let store: PlazaStore
    var detail: Bool
    @State private var viewing: Int?
    @Environment(OnboardingStore.self) private var language
    @Environment(\.displayScale) private var displayScale
    private var count: Int { post.images.isEmpty ? post.linkedPages.count : post.images.count }
    private var columns: Int { count == 1 ? 1 : [2, 4].contains(count) ? 2 : 3 }
    var body: some View {
        GeometryReader { proxy in
            let size = geometry(width: proxy.size.width)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<Int(ceil(Double(count) / Double(columns))), id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(row * columns..<min(count, (row + 1) * columns), id: \.self) { index in
                            Group {
                                if post.images.isEmpty, let work = post.objectExtensions?.illust {
                                    // Stay in the registered app stack so author/related-work links keep working.
                                    NavigationLink(value: work) {
                                        PixivAsyncImage(url: URL(string: post.linkedPages[index]), showsProgress: false, placeholder: Theme.v3Surface2)
                                            .blur(radius: ((work.xRestrict ?? 0) > 0 || MuteStore.shared.isIllustMuted(work.id)) ? 25 : 0)
                                    }
                                } else {
                                    Button { viewing = index } label: {
                                        PlazaRemoteImage(url: URL(string: post.images[index].url), pixels: Int(size.width * displayScale), refresh: refreshImages)
                                    }
                                }
                            }
                            .buttonStyle(.plain).frame(width: size.width, height: size.height)
                            .clipped().clipShape(RoundedRectangle(cornerRadius: count == 1 ? 16 : 12))
                            .accessibilityLabel(PlazaCopy(tag: language.activeTag).format("image_accessibility", String(index + 1), String(count)))
                        }
                    }
                }
            }
        }
        .frame(height: gridHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            PlazaImageViewer(postID: post.id, store: store, initialIndex: viewing ?? 0)
        }
        .task(id: post.id) {
            if post.needsFreshImages { await refreshImages() }
        }
    }
    private func refreshImages() async {
        do { try await store.fetch(post.id, force: true) }
        catch is CancellationError { }
        catch { store.failure = error }
    }
    @State private var width: CGFloat = 320
    private func geometry(width: CGFloat) -> CGSize {
        let first = post.images.first
        let w = CGFloat(first?.width ?? post.objectExtensions?.illust?.width ?? 1)
        let h = CGFloat(first?.height ?? post.objectExtensions?.illust?.height ?? 1)
        let tile = floor((width - CGFloat(columns - 1) * 4) / CGFloat(columns))
        if count == 1 {
            let actual = !detail && h > w ? floor(width * 0.55) : width
            return .init(width: actual, height: min(detail ? 900 : 480, floor(actual * h / max(w, 1))))
        }
        return .init(width: tile, height: tile)
    }
    private var gridHeight: CGFloat {
        let rows = CGFloat(ceil(Double(count) / Double(columns)))
        return geometry(width: width).height * rows + max(0, rows - 1) * 4
    }
}

struct PlazaRemoteImage: View {
    let url: URL?
    var pixels = 600
    var refresh: (() async -> Void)?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        ZStack {
            PlazaPalette.primary.opacity(0.08)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if failed {
                Button {
                    Task { failed = false; await refresh?(); attempt += 1 }
                } label: { Image(systemName: "arrow.clockwise").padding(16) }
            }
            else { ProgressView() }
        }.task(id: "\(url?.absoluteString ?? "")-\(pixels)-\(attempt)") {
            guard let url else { failed = true; return }
            do {
                failed = false
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let limit = max(1, min(pixels, 2048))
                let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: limit, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                    return UIImage(cgImage: cg)
                }.value
                try Task.checkCancellation()
                image = decoded; failed = decoded == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct PlazaImageViewer: View {
    let postID: Int64
    let store: PlazaStore
    var initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var language
    @State private var index = 0
    @State private var error: Error?
    private var images: [PlazaImage] { store.posts[postID]?.images ?? [] }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.element.id) { i, image in
                    PlazaZoomPage(url: URL(string: image.url), refresh: { await refresh(force: true) }).tag(i)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            HStack {
                Button { dismiss() } label: { PlazaIcon(glyph: .close).frame(width: 48, height: 48) }
                    .accessibilityLabel(PlazaCopy(tag: language.activeTag).text("close"))
                Spacer()
                Text("\(min(index + 1, images.count)) / \(images.count)").font(.montserratMedium(14)).padding(16)
            }.foregroundStyle(.white).background(.black.opacity(0.4))
            if let error {
                PlazaStateView(text: PlazaCopy(tag: language.activeTag).error(error), error: true,
                               actionTitle: PlazaCopy(tag: language.activeTag).text("retry")) { Task { await refresh() } }
                    .frame(maxHeight: .infinity)
            }
        }
        .task { index = initialIndex; await refresh() }
    }
    private func refresh(force: Bool = false) async {
        do { error = nil; try await store.fetch(postID, force: force) }
        catch { self.error = error }
    }
}

/// Camera JPEGs retain EXIF orientation because uploads preserve original bytes.
/// Orient the tiled scroll surface instead of decoding a full-resolution bitmap.
struct PlazaOrientedZoomView: View {
    let source: TileImageSource
    let orientation: CGImagePropertyOrientation
    private var swapsAxes: Bool { orientation.rawValue >= 5 }
    private var mirrored: Bool { [2, 4, 5, 7].contains(orientation.rawValue) }
    private var degrees: Double {
        switch orientation {
        case .down, .downMirrored: return 180
        case .right, .leftMirrored: return 90
        case .left, .rightMirrored: return 270
        default: return 0
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ZoomImageScrollView(source: source, onSingleTap: {})
                .id(ObjectIdentifier(source))
                .frame(width: swapsAxes ? geometry.size.height : geometry.size.width,
                       height: swapsAxes ? geometry.size.width : geometry.size.height)
                .rotationEffect(.degrees(degrees))
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.clipped()
    }
}

private struct PlazaZoomPage: View {
    let url: URL?
    var refresh: () async -> Void
    @State private var source: TileImageSource?
    @State private var orientation: CGImagePropertyOrientation = .up
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        ZStack {
            if let source { PlazaOrientedZoomView(source: source, orientation: orientation) }
            else if failed { Button { Task { await refresh(); retry += 1 } } label: { Image(systemName: "arrow.clockwise").font(.title).padding(24) } }
            else { ProgressView().tint(.white) }
        }.task(id: "\(url?.absoluteString ?? "")-\(retry)") {
            guard let url else { return }
            do {
                failed = false
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let decoded = await Task.detached(priority: .userInitiated) {
                    (TileImageSource(data: data), PlazaPhotoFiles.orientation(of: data))
                }.value
                try Task.checkCancellation()
                orientation = decoded.1; source = decoded.0; failed = decoded.0 == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
