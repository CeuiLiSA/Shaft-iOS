import SwiftUI

enum PlazaRoute: Hashable { case post(Int64), blocks }

struct PlazaView: View {
    @State private var store: PlazaStore
    @State private var all = PlazaPageModel()
    @State private var mine = PlazaPageModel()
    @State private var onlyMine = false
    @State private var composing = false
    @State private var selected: Int64?
    @State private var showFAB = true
    @Environment(OnboardingStore.self) private var language
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(store: PlazaStore? = nil) { _store = State(initialValue: store ?? PlazaStore()) }
    private var copy: PlazaCopy { .init(tag: language.activeTag) }
    private var page: PlazaPageModel { onlyMine ? mine : all }
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("plaza-top")
                    if !page.loaded && page.loading { PlazaSkeleton() }
                    else if page.ids.isEmpty {
                        if let error = page.error {
                            PlazaStateView(text: copy.error(error), error: true, actionTitle: copy.text("retry")) { Task { await reload() } }
                        } else {
                            PlazaStateView(text: copy.text(onlyMine ? "mine_empty_desc" : "empty_desc"), actionTitle: copy.text("compose_title")) { composing = true }
                        }
                    } else {
                        ForEach(page.ids, id: \.self) { id in
                            if let post = store.posts[id] {
                                PlazaPostView(post: post, store: store, onReply: { selected = id })
                                    .onTapGesture { selected = id }
                                    .accessibilityIdentifier("plaza-post-\(id)")
                                Rectangle().fill(Theme.v3PageDivider).frame(height: 0.5)
                            }
                        }
                        if let error = page.error {
                            Button(copy.error(error) + " · " + copy.text("retry")) { Task { await loadMore() } }
                                .padding(16).frame(minHeight: 48)
                        } else if page.next != nil {
                            ProgressView().padding(20).task(id: page.next) { await loadMore() }
                        }
                    }
                }.frame(maxWidth: 720).frame(maxWidth: .infinity).padding(.bottom, 96)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                if new <= 0 || new < old - 8 { showFAB = true }
                else if new > old + 8 { showFAB = false }
            }
            .refreshable { await reload() }
            .overlay(alignment: .bottomTrailing) {
                if showFAB {
                    Button { composing = true } label: {
                        HStack(spacing: 8) {
                            PlazaIcon(glyph: .add)
                            PlazaText(value: copy.text("compose_title"), size: 14, weight: 600, color: .white)
                        }.padding(.leading, 20).padding(.trailing, 24).frame(minHeight: 52)
                            .foregroundStyle(.white).background(PlazaPalette.primary, in: Capsule())
                    }.buttonStyle(PlazaPressStyle()).padding(16)
                        .frame(maxWidth: 720, alignment: .trailing).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("plaza-compose")
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                PlazaToolbar(back: { dismiss() }) {
                    HStack(spacing: 0) {
                        segment(false, title: copy.text("filter_all"))
                        segment(true, title: copy.text("filter_mine"))
                    }.padding(3).background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 17))
                } trailing: {
                    Menu {
                        NavigationLink(value: PlazaRoute.blocks) { Text(copy.text("blocked_users")) }
                    } label: { PlazaIcon(glyph: .more).frame(width: 48, height: 48) }
                    .accessibilityLabel(copy.text("more_menu"))
                }
            }
            .navigationDestination(item: $selected) { id in PlazaDetailView(postID: id, store: store) }
            .navigationDestination(for: PlazaRoute.self) { route in
                switch route {
                case .post(let id): PlazaDetailView(postID: id, store: store)
                case .blocks: PlazaBlocksView(store: store)
                }
            }
            .fullScreenCover(isPresented: $composing) {
                PlazaComposeView(store: store) { _ in
                    composing = false
                    Task { await reload(); scroll.scrollTo("plaza-top", anchor: .top) }
                }
            }
            .task(id: onlyMine) { await reload() }
            .onChange(of: store.structureRevision) { _, _ in Task { await reload() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
            .plazaErrorAlert(store: store, copy: copy)
            .plazaScreen()
        }
    }
    private func segment(_ mine: Bool, title: String) -> some View {
        Button { onlyMine = mine } label: {
            PlazaText(value: title, size: 14, weight: 600, color: onlyMine == mine ? Color(hex: 0x1F1F1F) : .white)
                .padding(.horizontal, 16).padding(.vertical, 7).frame(minWidth: 88, minHeight: 36)
                .background(onlyMine == mine ? .white : .clear, in: RoundedRectangle(cornerRadius: 14))
        }.accessibilityAddTraits(onlyMine == mine ? .isSelected : [])
            .accessibilityIdentifier(mine ? "plaza-filter-mine" : "plaza-filter-all")
    }
    private func reload() async { await page.load(store: store, author: onlyMine ? store.uid : nil, reset: true) }
    private func loadMore() async { await page.load(store: store, author: onlyMine ? store.uid : nil, reset: false) }
}

struct PlazaDetailView: View {
    let postID: Int64
    let store: PlazaStore
    @State private var comments = PlazaPageModel()
    @State private var composer: PlazaComposerModel
    @State private var error: Error?
    @State private var selected: Int64?
    @State private var policy = false
    @State private var stickers = false
    @State private var stickerPosition = StickerPickerPosition()
    @State private var stickerKeyboardHeight: CGFloat = 270
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var language
    @Environment(\.scenePhase) private var scenePhase
    init(postID: Int64, store: PlazaStore) {
        self.postID = postID; self.store = store
        _composer = State(initialValue: PlazaComposerModel(uid: store.uid, replyTo: postID))
    }
    private var copy: PlazaCopy { .init(tag: language.activeTag) }
    private var post: PlazaPost? { store.posts[postID] }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let post {
                    if let parent = post.replyTo {
                        NavigationLink(value: PlazaRoute.post(parent)) {
                            PlazaText(value: copy.text("reply_post") + " #\(parent) ›", size: 13, color: PlazaPalette.accent)
                        }.padding(16)
                    }
                    PlazaPostView(post: post, store: store, detail: true, onReply: { focused = true; stickers = false })
                    PlazaSectionLabel(text: copy.format("comments_title", String(post.replyCount)))
                        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
                    if comments.ids.isEmpty && comments.loaded && comments.error == nil {
                        PlazaStateView(text: copy.text("comments_empty"))
                    }
                    ForEach(comments.ids, id: \.self) { id in
                        if let comment = store.posts[id] {
                            PlazaPostView(post: comment, store: store, comment: true, onReply: {
                                composer.edit { $0.replyTo = id; $0.replyName = comment.displayName; $0.replyPreview = comment.text }
                                focused = true; stickers = false
                            }).onTapGesture { selected = id }
                            Rectangle().fill(Theme.v3PageDivider).frame(height: 0.5)
                        }
                    }
                    if let error = comments.error {
                        Button(copy.error(error) + " · " + copy.text("retry")) { Task { await loadComments(reset: comments.ids.isEmpty) } }
                            .padding(16)
                    } else if comments.loading || comments.next != nil {
                        ProgressView().padding(20).frame(maxWidth: .infinity)
                            .task(id: comments.next) { if comments.next != nil { await loadComments(reset: false) } }
                    }
                    if let error { PlazaText(value: copy.error(error), color: Theme.v3Danger).padding(16) }
                } else if store.deleted.contains(postID) {
                    PlazaStateView(text: copy.text("not_found"))
                } else if let error {
                    PlazaStateView(text: copy.error(error), error: true, actionTitle: copy.text("retry")) { Task { await load(force: true) } }
                } else { PlazaSkeleton() }
            }.frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .refreshable { await load(force: true) }
        .safeAreaInset(edge: .top, spacing: 0) {
            PlazaToolbar(back: { dismiss() }) {
                PlazaText(value: copy.text("post_detail_title"), size: 18, color: .white)
            } trailing: { if let post { PlazaPostMenu(post: post, store: store, color: .white) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if post != nil { replyBar }
        }
        .navigationDestination(item: $selected) { id in PlazaDetailView(postID: id, store: store) }
        .task { await load(force: false) }
        .task { await composer.loadAvatar() }
        .onChange(of: store.structureRevision) { _, _ in Task { await load(force: true) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load(force: false) } } }
        .onChange(of: focused) { _, value in if value { stickers = false } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard focused, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let inset = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
            stickerKeyboardHeight = max(180, frame.height - inset)
        }
        .alert(copy.text("policy_title"), isPresented: $policy) {
            Button(copy.text("cancel"), role: .cancel) {}
            Button(copy.text("policy_accept")) {
                do { try PlazaPolicy.accept(uid: store.uid); send() } catch { composer.error = error }
            }
        } message: { Text(copy.text("policy_body")) }
        .plazaErrorAlert(store: store, copy: copy)
        .plazaScreen()
    }
    private var replyBar: some View {
        VStack(spacing: 0) {
            if composer.draft.replyTo != postID, let name = composer.draft.replyName {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5).fill(PlazaPalette.primary).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        PlazaText(value: copy.text("reply") + " " + name, size: 13, weight: 600, color: PlazaPalette.accent).lineLimit(1)
                        PlazaText(value: composer.draft.replyPreview ?? "", size: 13, color: Theme.v3Text2).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { composer.edit { $0.replyTo = postID; $0.replyName = nil; $0.replyPreview = nil } } label: {
                        PlazaIcon(glyph: .close).frame(width: 36, height: 36)
                    }.accessibilityLabel(copy.text("close"))
                }.fixedSize(horizontal: false, vertical: true).padding(8)
                    .background(PlazaPalette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 12).padding(.top, 10)
            }
            if let error = composer.error {
                PlazaText(value: copy.error(error), size: 13, color: Theme.v3Danger).padding(.horizontal, 16).padding(.top, 8)
            }
            HStack(spacing: 0) {
                Button {
                    if stickers { stickers = false; focused = true }
                    else { focused = false; stickers = true }
                } label: {
                    // Shared chat composer style (2026-09-24): 48pt hit area, textAccent tint.
                    Group {
                        if stickers { Image(systemName: "keyboard").font(.system(size: 22)) }
                        else { PlazaIcon(glyph: .emoji) }
                    }.foregroundStyle(Theme.v3TextAccent).frame(width: 48, height: 48).contentShape(.rect)
                }.accessibilityLabel(copy.text("sticker_title"))
                TextField(text: Binding(get: { composer.draft.text }, set: { value in composer.edit { $0.text = value } }), axis: .vertical) {
                    Text(copy.text("comment_hint")).foregroundStyle(Theme.v3Text2)
                }
                    .font(.custom("Montserrat-Regular", size: 15)).lineLimit(1...4).focused($focused)
                    // Disabled while sending: text steps back to v3_text_2.
                    .foregroundStyle(composer.sending ? Theme.v3Text2 : Theme.v3Text1).tint(Theme.v3TextAccent)
                    .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 48)
                    .background(ChatComposerStyle.composerField, in: RoundedRectangle(cornerRadius: 22))
                    .padding(.leading, 2).padding(.trailing, 4)
                    .accessibilityIdentifier("plaza-reply-input")
                Button { if PlazaPolicy.accepted(uid: store.uid) { send() } else { policy = true } } label: {
                    let enabled = composer.canSend && !store.busy
                    Group { if composer.sending { ProgressView().tint(Theme.v3TextAccent) } else { PlazaIcon(glyph: .send, size: 20) } }
                        .frame(width: 40, height: 40)
                        .foregroundStyle(enabled ? Color.white : Theme.v3TextAccent.opacity(0.45))
                        .background(enabled ? AnyShapeStyle(PlazaPalette.primary) : AnyShapeStyle(ChatComposerStyle.sendDisabled), in: Circle())
                        .frame(width: 48, height: 48).contentShape(.rect)
                }.disabled(!composer.canSend || store.busy).accessibilityLabel(copy.text("send"))
            }.padding(.horizontal, 8).padding(.vertical, 10).disabled(composer.sending)
            if stickers {
                PlazaStickerPicker(inline: true, position: stickerPosition) { sticker in
                    guard !composer.sending else { return }
                    if let post {
                        let reaction = post.reactions?.first { $0.stickerId == sticker.id }
                            ?? PlazaReaction(emoji: "sticker:\(sticker.id)", count: 0, selected: false, stickerId: sticker.id)
                        Task { await store.react(post, reaction) }
                    }
                }.frame(height: stickerKeyboardHeight)
            }
        }.frame(maxWidth: 720).frame(maxWidth: .infinity)
            .background(ChatComposerStyle.composerSurface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Theme.v3CardHairline.frame(height: 0.5) }
    }
    private func load(force: Bool) async {
        guard !store.deleted.contains(postID) else { return }
        do { error = nil; try await store.fetch(postID, force: force) }
        catch is CancellationError { return }
        catch { self.error = error }
        if post != nil { await loadComments(reset: true) }
    }
    private func loadComments(reset: Bool) async { await comments.load(store: store, replyTo: postID, reset: reset) }
    private func send() {
        Task {
            if await composer.send(store: store) != nil {
                focused = false; stickers = false
                await load(force: true)
            }
        }
    }
}

extension View {
    func plazaErrorAlert(store: PlazaStore, copy: PlazaCopy) -> some View {
        alert(copy.text("error_title"), isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            Button(copy.text("understood")) { store.failure = nil }
        } message: { if let error = store.failure { Text(copy.error(error)) } }
    }
}
