import SwiftUI

// Card long-press menus — 1:1 with upstream `IllustCardMenu.showCardMenu` and
// `NovelCardMenu.showNovelCardMenu`. The menu rows themselves are cheap, but
// several of them need a presenter (a sheet, a push, a full-screen cover, a
// toast) and SwiftUI wants exactly one of each per list, not one per cell. So
// a list installs `.cardMenuHost()` once, and every cell's menu talks to the
// shared `CardMenuCoordinator` it publishes through the environment.

/// Presentation state shared by all cards of one list.
@MainActor
@Observable
final class CardMenuCoordinator {
    struct MuteSheetSeed: Identifiable {
        let id = UUID()
        let tags: [Tag]
        let user: PixivUser?
    }

    var commentTarget: AppRoute.CommentTarget?
    var muteSheet: MuteSheetSeed?
    var illustBulkSeed: BulkSelectionSeed?
    var novelBulkSeed: NovelBulkSelectionSeed?
    var slideshowSeed: SlideshowSeed?
    var toast: String?

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// `Common.showToast` — a short capsule at the top of the list.
    func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

private struct CardMenuHostModifier: ViewModifier {
    @State private var coordinator = CardMenuCoordinator()

    func body(content: Content) -> some View {
        @Bindable var coordinator = coordinator
        content
            .environment(coordinator)
            // "查看评论": same destination as `RouteHost`'s `.comments` registration.
            // A `NavigationLink` inside a context menu doesn't reliably push; a
            // state-driven destination does.
            .navigationDestination(item: $coordinator.commentTarget) { target in
                CommentsView(target: target)
                    .toolbar(.hidden, for: .tabBar)
                    .background(SwipeBackEnabler())
            }
            // "屏蔽设定" — `MuteTagSheet.show(fm, tags, user)`.
            .sheet(item: $coordinator.muteSheet) { seed in
                MuteTargetsSheet(tags: seed.tags, user: seed.user)
            }
            .fullScreenCover(item: $coordinator.illustBulkSeed) { seed in
                BulkSelectView(illusts: seed.illusts)
            }
            .fullScreenCover(item: $coordinator.novelBulkSeed) { seed in
                NovelBulkSelectView(novels: seed.novels)
            }
            .fullScreenCover(item: $coordinator.slideshowSeed) { seed in
                SlideshowView(seed: seed)
            }
            .overlay(alignment: .top) {
                if let toast = coordinator.toast {
                    // Hosts embedded in a taller scroll page (profile novel tab,
                    // rank strip) anchor at content top, which may be scrolled
                    // away — pin to the scroll viewport instead.
                    GeometryReader { geo in
                        Text(toast)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.black.opacity(0.82), in: .capsule)
                            .foregroundStyle(.white)
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity)
                            .offset(y: max(0, -geo.frame(in: .scrollView).minY))
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: coordinator.toast)
    }
}

extension View {
    /// Install once on a list container whose cells use `.illustCardMenu` /
    /// `.novelCardMenu`.
    func cardMenuHost() -> some View { modifier(CardMenuHostModifier()) }
}

// MARK: - Illust card menu (`IllustCardMenu.showCardMenu`)

/// Rows of the illust-card long-press menu, in upstream order: 屏蔽/取消屏蔽此作品 ·
/// 屏蔽设定 · 查看评论 · 批量操作 · 下载这个作品 · 幻灯片 · 稍后再看. The iOS-only
/// share / copy / open rows follow after a divider.
///
/// `scoped` is the list the bulk / slideshow actions operate on — evaluated only
/// when that row is tapped, so opening the menu never copies the list.
struct IllustCardMenuItems: View {
    let illust: Illust
    let scoped: () -> [Illust]

    @Environment(CardMenuCoordinator.self) private var coordinator: CardMenuCoordinator?
    @Environment(OnboardingStore.self) private var l10n
    @State private var mute = MuteStore.shared
    @State private var watchLater = WatchLaterStore.shared

    var body: some View {
        let spoilered = mute.isIllustMuted(illust.id)
        Button {
            mute.setIllustMuted(illust.id, !spoilered)
        } label: {
            Label(l10n.t(spoilered ? .cardUnmuteWork : .cardMuteWork),
                  systemImage: spoilered ? "eye" : "eye.slash")
        }
        Button {
            coordinator?.muteSheet = .init(tags: illust.tags ?? [], user: illust.user)
        } label: {
            Label(l10n.t(.artworkV3MuteSettings), systemImage: "gearshape")
        }
        Button {
            coordinator?.commentTarget = .illust(illust.id)
        } label: {
            Label(l10n.t(.cardViewComments), systemImage: "bubble.left")
        }
        Button {
            let beans = scoped()
            guard !beans.isEmpty else { return }
            coordinator?.illustBulkSeed = BulkSelectionSeed(illusts: beans)
        } label: {
            Label(l10n.t(.bulkActionsEntry), systemImage: "checklist")
        }
        Button {
            // `IllustDownload.downloadIllustAllPages` + `isAutoPostLikeWhenDownload`.
            let n = DownloadManager.shared.enqueue([illust])
            if AppSettingsStore.shared.autoPostLikeWhenDownload,
               !InteractionStore.shared.isBookmarked(illust) {
                Task { try? await InteractionStore.shared.toggleBookmark(illust) }
            }
            coordinator?.flash(l10n.t(.dlEnqueuedFmt, "\(n)"))
        } label: {
            Label(l10n.t(.cardDownloadWork), systemImage: "arrow.down.circle")
        }
        Button {
            coordinator?.slideshowSeed = SlideshowBuilder.seed(from: scoped(), tapped: illust)
        } label: {
            Label(l10n.t(.slideshowPlay), systemImage: "play.rectangle.on.rectangle")
        }
        let saved = watchLater.contains(illust.id)
        Button {
            let nowSaved = watchLater.toggle(illust)
            coordinator?.flash(l10n.t(nowSaved ? .watchLaterAdded : .watchLaterRemoved))
        } label: {
            Label(l10n.t(saved ? .watchLaterRemove : .watchLaterAdd),
                  systemImage: saved ? "minus.circle" : "clock.badge.checkmark")
        }
        Divider()
        IllustCellContextMenuItems(illust: illust)
    }
}

// MARK: - Novel card menu (`NovelCardMenu.showNovelCardMenu`)

/// Rows of the novel-card long-press menu, in upstream order: 屏蔽/取消屏蔽此作品 ·
/// 屏蔽设定 · 查看评论 · 批量操作 · 下载这个作品 · 稍后再看, then the iOS-only
/// share / copy / open rows after a divider.
struct NovelCardMenuItems: View {
    let novel: Novel
    let scoped: () -> [Novel]

    @Environment(CardMenuCoordinator.self) private var coordinator: CardMenuCoordinator?
    @Environment(OnboardingStore.self) private var l10n
    @State private var mute = MuteStore.shared
    @State private var watchLater = WatchLaterStore.shared

    var body: some View {
        let spoilered = mute.isNovelMuted(novel.id)
        Button {
            mute.setNovelMuted(novel.id, !spoilered)
        } label: {
            Label(l10n.t(spoilered ? .cardUnmuteWork : .cardMuteWork),
                  systemImage: spoilered ? "eye" : "eye.slash")
        }
        // Only when the sheet would have something to toggle (upstream skips the
        // row otherwise — tapping it would do nothing).
        let tags = (novel.tags ?? []).filter { !($0.name ?? "").isEmpty }
        let author = novel.user.flatMap { $0.id != 0 ? $0 : nil }
        if !tags.isEmpty || author != nil {
            Button {
                coordinator?.muteSheet = .init(tags: tags, user: author)
            } label: {
                Label(l10n.t(.artworkV3MuteSettings), systemImage: "gearshape")
            }
        }
        Button {
            coordinator?.commentTarget = .novel(novel.id)
        } label: {
            Label(l10n.t(.cardViewComments), systemImage: "bubble.left")
        }
        Button {
            let novels = scoped()
            guard !novels.isEmpty else { return }
            coordinator?.novelBulkSeed = NovelBulkSelectionSeed(novels: novels)
        } label: {
            Label(l10n.t(.bulkActionsEntry), systemImage: "checklist")
        }
        Button {
            // `BatchDownloadNovelsTask(novels = listOf(novel))`.
            let l10n = l10n
            let coordinator = coordinator
            Task {
                let failures = await NovelDownloader.download([novel])
                coordinator?.flash(
                    failures.isEmpty
                        ? l10n.t(.batchDownloadAllOk)
                        : l10n.t(.batchDownloadSomeFailedFmt, "\(failures.count)")
                )
            }
        } label: {
            Label(l10n.t(.cardDownloadWork), systemImage: "arrow.down.circle")
        }
        let saved = watchLater.containsNovel(novel.id)
        Button {
            let nowSaved = watchLater.toggleNovel(novel)
            coordinator?.flash(l10n.t(nowSaved ? .watchLaterAdded : .watchLaterRemoved))
        } label: {
            Label(l10n.t(saved ? .watchLaterRemove : .watchLaterAdd),
                  systemImage: saved ? "minus.circle" : "clock.badge.checkmark")
        }
        Divider()
        NovelCellContextMenuItems(novel: novel)
    }
}

extension View {
    /// Novel-card long-press menu. The enclosing list must install `.cardMenuHost()`.
    func novelCardMenu(novel: Novel, scoped: @escaping () -> [Novel]) -> some View {
        contextMenu { NovelCardMenuItems(novel: novel, scoped: scoped) }
    }
}

// MARK: - Spoiler mask (`SpoilerBlurView` on a muted card)

/// The in-place mask a muted card keeps over itself: the card stays where it is,
/// blurred, and a tap lifts the mute instead of opening the work (upstream
/// `unmuteOr`). Upstream floats particles over the blur; iOS settles for the
/// blur plus the eye glyph, which carries the meaning.
struct CardSpoilerMask: View {
    let onReveal: () -> Void

    var body: some View {
        // An inner Button wins the tap over the cell's NavigationLink.
        Button(action: onReveal) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Image(systemName: "eye.slash.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(.plain)
    }
}
