import SwiftUI

/// "稍后再看" (Watch Later) list page — 1:1 port of upstream `WatchLaterFragment`:
/// a waterfall of the locally-saved works, most-recently-added first, with a
/// toolbar menu for "播放全部" (slideshow the whole list, shuffled) and "清空列表"
/// (clear, behind a confirm). Empty state mirrors `watch_later_empty`.
///
/// Storage lives in `WatchLaterStore`; because it's `@Observable`, adding or
/// removing a work from any card long-press updates this list live — the iOS
/// equivalent of upstream's `ACTION_WATCH_LATER_CHANGED` broadcast (upstream
/// deliberately avoids an onResume hard-reload so optimistic bookmark hearts
/// don't snap back; here the store simply is the source of truth, no reload).
struct WatchLaterView: View {
    @State private var store = WatchLaterStore.shared
    @State private var slideshowSeed: SlideshowSeed?
    @State private var showClearConfirm = false
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView(l10n.t(.watchLaterEmpty), systemImage: "clock.badge.checkmark")
            } else {
                // Local list: never loading, no errors, no pagination.
                // `prefiltered: true` — show every saved work, do NOT apply the
                // mute/R-18 filter. Parity with upstream `WatchLaterViewModel`,
                // which renders the raw DB rows unfiltered (a personal curated
                // queue, like bookmarks); filtering here would silently hide works
                // the user explicitly saved, and hide the list entirely if every
                // saved artist happened to be muted.
                IllustWaterfallList(
                    illusts: store.items,
                    isLoading: false,
                    errorMessage: nil,
                    onRefresh: {},
                    prefiltered: true
                )
            }
        }
        .navigationTitle(l10n.t(.watchLaterTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        // "播放全部": shuffle the whole saved list (upstream
                        // `SlideshowLauncher.launchFromIllustsBeans`, random = true).
                        if let first = store.items.first {
                            slideshowSeed = SlideshowBuilder.seed(from: store.items, tapped: first)
                        }
                    } label: {
                        Label(l10n.t(.watchLaterPlayAll), systemImage: "play.rectangle.on.rectangle")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label(l10n.t(.watchLaterClear), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(store.items.isEmpty)
            }
        }
        .confirmationDialog(
            l10n.t(.watchLaterClearConfirm),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(l10n.t(.watchLaterClearOk), role: .destructive) { store.clear() }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
        .fullScreenCover(item: $slideshowSeed) { SlideshowView(seed: $0) }
    }
}
