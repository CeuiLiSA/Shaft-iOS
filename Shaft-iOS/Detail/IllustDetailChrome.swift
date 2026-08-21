import SwiftUI
import UIKit

// Chrome that floats over the V3 illust detail page — the pieces upstream keeps
// outside the list in `fragment_artwork_v3.xml` and its dialogs: the overflow
// menu (`V3MenuDialog`), the whole-page mute mask (`abandoned_frame`), the
// mute-settings sheet (`MuteTagSheet`), the on-demand comment composer
// (`CommentComposerController`), and the share sheet `ShareIllust` stands in for.

// MARK: - V3 menu dialog (`V3MenuDialog` / `dialog_v3_menu.xml`)

/// One row of `item_v3_menu_row.xml`: 22dp icon tinted `v3_text_2`, 16dp gap,
/// 15sp `v3_text_1` label, 24×15 padding.
struct V3MenuRow: Identifiable {
    let id = UUID()
    let title: String
    /// SF Symbol standing in for the upstream vector drawable.
    let icon: String
    let action: () -> Void
}

extension View {
    /// Presents `rows` the way `V3MenuDialog` does: a centered card at 78 % of
    /// the screen width, r=24, `settingsCardBg` fill + 1dp hairline, 8dp
    /// vertical padding, over a 50 % scrim.
    func v3MenuDialog(isPresented: Binding<Bool>, rows: [V3MenuRow]) -> some View {
        modifier(V3MenuDialogModifier(isPresented: isPresented, rows: rows))
    }
}

private struct V3MenuDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let rows: [V3MenuRow]

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            Button {
                                isPresented = false
                                row.action()
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: row.icon)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.v3Text2)
                                        .frame(width: 22, height: 22)
                                    Text(row.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.v3Text1)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 15)
                                .contentShape(.rect)
                            }
                            .buttonStyle(V3MenuRowStyle())
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(width: UIScreen.main.bounds.width * 0.78)
                    .background(Theme.v3CardFill, in: .rect(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.v3CardHairline, lineWidth: 1))
                    .clipShape(.rect(cornerRadius: 24))
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPresented)
    }
}

/// `?attr/selectableItemBackground` on a menu row.
private struct V3MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.v3Surface2 : Color.clear)
    }
}

// MARK: - Mute mask (`abandoned_frame`)

/// The whole-page mask a muted work (or a muted artist) draws over the detail
/// page — a blurred cover with the unmute / leave affordances on top. Upstream
/// also floats spoiler particles over it (`SpoilerBlurView`); iOS settles for
/// the blur, which is the part that carries the meaning.
struct MuteMaskOverlay: View {
    let illust: Illust
    let illustMuted: Bool
    let userMuted: Bool
    var onUnmuteIllust: () -> Void
    var onUnmuteUser: () -> Void
    var onLeave: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ZStack {
            Color.black
            PixivAsyncImage(url: coverURL, showsProgress: false)
                .blur(radius: 40)
                .opacity(0.55)
                .clipped()
            VStack(spacing: 20) {
                if illustMuted {
                    maskButton(l10n.t(.artworkV3UnmuteWork), tint: Theme.v3Blue, action: onUnmuteIllust)
                }
                if userMuted {
                    maskButton(l10n.t(.artworkV3UnmuteUser), tint: Theme.v3Blue, action: onUnmuteUser)
                }
                maskButton(l10n.t(.artworkV3LeavePage), tint: Theme.v3Pink, action: onLeave)
            }
        }
        .ignoresSafeArea()
        // `android:clickable="true"` — the mask swallows everything under it.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    /// `BlueShiningButton` / `RedShiningButton`: 45dp tall, 20dp side padding.
    private func maskButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 45)
                .background(tint, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var coverURL: URL? {
        (illust.imageUrls?.medium ?? illust.imageUrls?.squareMedium).flatMap(URL.init(string:))
    }
}

// MARK: - Mute settings sheet (`MuteTagSheet`)

/// `MuteTagSheet.show(fm, illust.tags, illust.user)` — pick which of this work's
/// tags (and its artist) to mute, toggled straight against `MuteStore`.
struct MuteTargetsSheet: View {
    let tags: [Tag]
    let user: PixivUser?
    @State private var mute = MuteStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationStack {
            List {
                if let user {
                    Section {
                        Toggle(isOn: Binding(
                            get: { mute.isUserMuted(user.id) },
                            set: { _ in mute.toggleUser(user.id) }
                        )) {
                            Text(user.name ?? "")
                        }
                    }
                }
                Section(l10n.t(.detailTagsLabel)) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                        let name = tag.name ?? ""
                        Toggle(isOn: Binding(
                            get: { mute.isTagMuted(name) },
                            set: { _ in mute.toggleTag(name) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("# " + name)
                                if let t = tag.translatedName, !t.isEmpty {
                                    Text(t).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(l10n.t(.artworkV3MuteSettings))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Inline comment composer (`CommentComposerController`)

/// The composer the "留下你的评论吧" entry raises. Upstream floats it over the
/// list on demand and hides the FAB bar while it's up; a sheet is the iOS
/// equivalent of that "not normally resident" behaviour.
struct CommentComposerSheet: View {
    /// Returns true once the comment has been accepted.
    let onSend: (String) async -> Bool

    @State private var draft = ""
    @State private var isSending = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField(l10n.t(.artworkV3AddCommentHint), text: $draft, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($focused)
                    .padding(12)
                    .background(Theme.v3CardFill, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.v3CardHairline, lineWidth: 1))
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(l10n.t(.commentsTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSending = true
                            let ok = await onSend(draft)
                            isSending = false
                            if ok { dismiss() }
                        }
                    } label: {
                        Image(systemName: isSending ? "ellipsis" : "paperplane.fill")
                    }
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(l10n.t(.commentReply))
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Share (`ShareIllust` / `shareFirstImage`)

/// Either the work's pixiv URL (`ShareIllust`) or its first page as an image
/// (`shareFirstImage`).
struct ShareTarget: Identifiable {
    let id = UUID()
    let items: [Any]

    init(url: URL) { items = [url] }
    init(image: UIImage) { items = [image] }
}

struct V3ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
