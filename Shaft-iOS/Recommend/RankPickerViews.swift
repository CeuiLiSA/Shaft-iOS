import SwiftUI

// MARK: - Option model + count formatting (RankPickerSheet.kt)

/// One pickable option. `key` is the server enum (tag 原文 / year / month); label
/// and sublabel are display text (translated tag first, original underneath).
struct RankPickerOption: Identifiable, Hashable {
    let key: String
    let label: String
    let sublabel: String
    let count: Int
    var id: String { key }
}

/// 12345 → "12.3k", 988 → "988". Decimal point pinned to "." regardless of locale
/// (ru/tr would print "20,0k").
func formatRankCount(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk", locale: Locale(identifier: "en_US"), Double(n) / 1000) : String(n)
}

// MARK: - Selector bar (rank_selector) + sheet (RankPickerSheet)

/// The full-width brand bar under the toolbar: "碧蓝档案 · 20.0k ▾". Tapping opens
/// the picker; while options are missing (failed) it shows the failure text and a
/// tap retries.
struct RankSelectorBar: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Theme.brand)
        }
        .buttonStyle(.plain)
    }
}

/// Bottom sheet listing the options: primary label + count, optional secondary
/// row, current item tinted accent; opens scrolled to the current item.
struct RankPickerSheet: View {
    let title: String
    let options: [RankPickerOption]
    let selectedKey: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)

            ScrollViewReader { proxy in
                List(options) { opt in
                    let selected = opt.key == selectedKey
                    Button {
                        onPick(opt.key)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(opt.label)
                                    .font(.system(size: 16))
                                    .foregroundStyle(selected ? Theme.v3TextAccent : Theme.v3Text1)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatRankCount(opt.count))
                                    .font(.system(size: 13))
                                    .foregroundStyle(selected ? Theme.v3TextAccent : Theme.v3Text3)
                            }
                            if !opt.sublabel.isEmpty {
                                Text(opt.sublabel)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.v3Text3)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                    .id(opt.key)
                }
                .listStyle(.plain)
                .onAppear {
                    if let key = selectedKey, options.contains(where: { $0.key == key }) {
                        proxy.scrollTo(key, anchor: .center)
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.88)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Picker page (RankPickerPageFragment): selector + sheet + feed

/// State of one "选择条 + feed" page. Options are fetched once per page (lazily,
/// when the page is first shown); the feed VM is re-pointed on every pick.
@MainActor
@Observable
final class RankPickerPageVM {
    let type: String
    let fetchOptions: @Sendable (String) async throws -> [RankPickerOption]
    let makeSource: (String, String) -> RankFeedSource
    var options: [RankPickerOption] = []
    var currentKey: String?
    var isLoadingOptions = false
    var loadFailed = false
    /// Feed VM; nil until an option is chosen (Android replaces the child feed then).
    var feed: RankWorksVM?
    @ObservationIgnored private var requested = false

    init(type: String,
         fetchOptions: @escaping @Sendable (String) async throws -> [RankPickerOption],
         makeSource: @escaping (String, String) -> RankFeedSource) {
        self.type = type
        self.fetchOptions = fetchOptions
        self.makeSource = makeSource
    }

    var selectorText: String? {
        guard let key = currentKey else { return nil }
        guard let opt = options.first(where: { $0.key == key }) else { return key }
        return "\(opt.label) · \(formatRankCount(opt.count))"
    }

    func loadOptionsIfNeeded() async {
        guard !requested else { return }
        requested = true
        await loadOptions()
    }

    /// Retry entry for the selector tap after a failure.
    func retryOptions() async {
        guard !isLoadingOptions else { return }
        requested = true
        await loadOptions()
    }

    private func loadOptions() async {
        isLoadingOptions = true
        loadFailed = false
        defer { isLoadingOptions = false }
        let fetched = (try? await fetchOptions(type)) ?? []
        if fetched.isEmpty {
            // Failed / empty: selector shows the failure text, next tap retries.
            loadFailed = true
            requested = false
            return
        }
        options = fetched
        // First build defaults to the first option (hottest tag / latest year);
        // a key that drifted out of the new list keeps showing as-is.
        if currentKey == nil { show(fetched[0].key) }
    }

    func pick(_ key: String) {
        guard key != currentKey else { return }   // same option → no reload
        show(key)
    }

    private func show(_ key: String) {
        currentKey = key
        let src = makeSource(type, key)
        if let feed {
            Task { await feed.setSource(src) }
        } else {
            feed = RankWorksVM(source: src)
        }
    }
}

struct RankPickerPage: View {
    let vm: RankPickerPageVM
    let pickTitle: String
    let loadFailedText: String
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            RankSelectorBar(text: vm.selectorText ?? (vm.loadFailed ? loadFailedText : "")) {
                if vm.options.isEmpty {
                    Task { await vm.retryOptions() }
                } else {
                    showPicker = true
                }
            }
            if let feed = vm.feed {
                RankWorksBody(vm: feed)
            } else if vm.isLoadingOptions {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                Spacer()
            }
        }
        .task { await vm.loadOptionsIfNeeded() }
        .sheet(isPresented: $showPicker) {
            RankPickerSheet(title: pickTitle, options: vm.options, selectedKey: vm.currentKey) { vm.pick($0) }
        }
    }
}

/// Type tabs (插画 / 漫画 / 小说) over per-type picker pages — the 标签专区 / 年代榜 host.
private struct RankPickerTabsView: View {
    let titleKey: LocalizedKey
    let pickKey: LocalizedKey
    let loadFailedKey: LocalizedKey
    @State private var selection = "illust"
    @State private var pages: [String: RankPickerPageVM]
    @Environment(OnboardingStore.self) private var l10n

    init(titleKey: LocalizedKey, pickKey: LocalizedKey, loadFailedKey: LocalizedKey,
         fetchOptions: @escaping @Sendable (String) async throws -> [RankPickerOption],
         makeSource: @escaping (String, String) -> RankFeedSource) {
        self.titleKey = titleKey
        self.pickKey = pickKey
        self.loadFailedKey = loadFailedKey
        let types = ["illust", "manga", "novel"]
        _pages = State(initialValue: Dictionary(uniqueKeysWithValues: types.map {
            ($0, RankPickerPageVM(type: $0, fetchOptions: fetchOptions, makeSource: makeSource))
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                Text(l10n.t(.profileIllusts)).tag("illust")
                Text(l10n.t(.profileManga)).tag("manga")
                Text(l10n.t(.profileNovels)).tag("novel")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if let page = pages[selection] {
                RankPickerPage(vm: page, pickTitle: l10n.t(pickKey), loadFailedText: l10n.t(loadFailedKey))
                    .id(selection)
            }
        }
        .navigationTitle(l10n.t(titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 标签专区 (TagRankFragment)

/// Options: /discover/tags?type= top-50 (translated first, original as sublabel);
/// feed: discover/most-bookmarked?type=&tag=.
struct TagRankView: View {
    var body: some View {
        RankPickerTabsView(
            titleKey: .tagRankTitle, pickKey: .tagRankPick, loadFailedKey: .tagRankLoadFailed,
            fetchOptions: { type in
                try await ShaftApiV2Client.shared.discoverTags(type: type, limit: 50).tags.map {
                    RankPickerOption(key: $0.tag, label: $0.translated ?? $0.tag,
                                     sublabel: $0.translated != nil ? $0.tag : "", count: $0.count)
                }
            },
            makeSource: { type, key in .bookmark(RankQuery(type: type, tag: key)) }
        )
    }
}

// MARK: - 年代榜 (YearRankFragment)

/// Options: /discover/years?type= (descending, with per-year counts — the
/// distribution is extremely skewed, so the count matters); feed: most-bookmarked?year=.
struct YearRankView: View {
    var body: some View {
        RankPickerTabsView(
            titleKey: .yearRankTitle, pickKey: .yearRankPick, loadFailedKey: .yearRankLoadFailed,
            fetchOptions: { type in
                try await ShaftApiV2Client.shared.discoverYears(type: type).map {
                    RankPickerOption(key: $0.year, label: $0.year, sublabel: "", count: $0.count)
                }
            },
            makeSource: { type, key in .bookmark(RankQuery(type: type, year: key)) }
        )
    }
}

// MARK: - 本月新作榜 (MonthRankFragment)

/// Month selector *above* the type tabs; months fetched once for illust only
/// (largest sample, fullest coverage — manga/novel tabs show the illust count),
/// default = newest. Picking a month re-points all three type feeds.
@MainActor
@Observable
private final class MonthRankVM {
    var buckets: [MonthBucket] = []
    var currentMonth: String?
    var isLoading = false
    var loadFailed = false
    @ObservationIgnored private var requested = false

    var selectorText: String? {
        guard let m = currentMonth else { return nil }
        guard let b = buckets.first(where: { $0.month == m }) else { return m }
        return "\(b.month) · \(formatRankCount(b.count))"
    }

    var options: [RankPickerOption] {
        buckets.map { RankPickerOption(key: $0.month, label: $0.month, sublabel: "", count: $0.count) }
    }

    func loadIfNeeded() async {
        guard !requested else { return }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        requested = true
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        let months = (try? await ShaftApiV2Client.shared.discoverMonths(type: "illust").months) ?? []
        if months.isEmpty {
            loadFailed = true
            requested = false
            return
        }
        buckets = months
        if currentMonth == nil { currentMonth = months[0].month }
    }

    func pick(_ month: String) {
        guard month != currentMonth else { return }
        currentMonth = month
    }
}

struct MonthRankView: View {
    @State private var vm = MonthRankVM()
    @State private var selection = "illust"
    @State private var showPicker = false
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            RankSelectorBar(text: vm.selectorText ?? (vm.loadFailed ? l10n.t(.monthRankLoadFailed) : "")) {
                if vm.buckets.isEmpty {
                    Task { await vm.load() }
                } else {
                    showPicker = true
                }
            }
            if let month = vm.currentMonth {
                RankTabbedFeed(
                    tabs: rankTypeTabs(l10n) { .bookmark(RankQuery(type: $0, month: month)) },
                    selection: $selection
                )
            } else if vm.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                Spacer()
            }
        }
        .navigationTitle(l10n.t(.monthRankTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showPicker) {
            RankPickerSheet(title: l10n.t(.monthRankPick), options: vm.options, selectedKey: vm.currentMonth) {
                vm.pick($0)
            }
        }
    }
}
