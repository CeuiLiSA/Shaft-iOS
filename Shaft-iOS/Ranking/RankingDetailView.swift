import SwiftUI

@MainActor
@Observable
final class RankingDetailViewModel {
    enum Kind: Hashable { case illust, manga, novel }

    var kind: Kind = .illust
    var mode: String
    /// Selected ranking date; `nil` = the latest published ranking (first entry).
    /// Parity with upstream `RankActivity` (a past-date picker over all sub-modes).
    var date: Date?
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(initialMode: String) {
        self.mode = initialMode
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    static func defaultMode(for kind: Kind) -> String {
        switch kind {
        case .illust: return "day"
        case .manga:  return "day_manga"
        case .novel:  return "day"
        }
    }

    /// Mode lists per content type, matching Shaft's `RankingFragment`. R-18
    /// variants are appended only when the user hasn't opted to hide R-18.
    static func modes(for kind: Kind, includeR18: Bool) -> [String] {
        switch kind {
        case .illust:
            // Order mirrors Shaft's FragmentRankIllust.API_TITLES.
            var m = ["day", "week", "month", "day_ai", "day_male", "day_female",
                     "week_original", "week_rookie"]
            if includeR18 { m += ["day_r18", "week_r18", "day_male_r18",
                                  "day_female_r18", "day_r18_ai", "week_r18g"] }
            return m
        case .manga:
            // FragmentRankIllust.API_TITLES_MANGA.
            var m = ["day_manga", "week_manga", "month_manga", "week_rookie_manga"]
            if includeR18 { m += ["day_r18_manga"] }
            return m
        case .novel:
            // FragmentRankNovel.API_TITLES_VALUES.
            var m = ["day", "week", "day_male", "day_female", "week_rookie"]
            if includeR18 { m += ["day_r18"] }
            return m
        }
    }

    func setKind(_ k: Kind) async {
        guard k != kind else { return }
        kind = k
        mode = Self.defaultMode(for: k)
        // Date doesn't cross content types — upstream opens a separate
        // RankActivity per 插画/漫画/小说, so switching kind returns to latest.
        date = nil
        await reset()
    }

    func setMode(_ m: String) async {
        guard m != mode else { return }
        mode = m
        // Date persists across sub-modes within a kind (upstream applies the
        // same picked date to day/week/month/AI/R18 alike).
        await reset()
    }

    /// Switch to a past date (or `nil` = latest) and reload.
    func setDate(_ d: Date?) async {
        date = d
        await reset()
    }

    private func reset() async {
        illusts = []
        novels = []
        nextUrl = nil
        await load()
    }

    func loadIfNeeded() async {
        if illusts.isEmpty && novels.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let dateParam = date.map { Self.ymd.string(from: $0) }
            switch kind {
            case .illust, .manga:
                let r = try await api.rankingIllusts(mode: mode, date: dateParam)
                illusts = r.illusts
                nextUrl = r.nextUrl
            case .novel:
                let r = try await api.rankingNovels(mode: mode, date: dateParam)
                novels = r.novels
                nextUrl = r.nextUrl
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Ranking date bounds & formatting (parity with upstream RankActivity)

    /// Latest selectable day = **yesterday** (upstream `now - 1 day`); pixiv's
    /// ranking publishes a day late, so today has no ranking yet.
    static var maxDate: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) ?? Date()
    }

    /// Earliest selectable day — upstream hard-codes `2008-01-01`.
    static var minDate: Date {
        Calendar.current.date(from: DateComponents(year: 2008, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 1199145600)
    }

    static func displayDate(_ d: Date) -> String { ymd.string(from: d) }

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        switch kind {
        case .illust, .manga:
            if let r: IllustResponse = try? await api.nextPage(url) {
                illusts.append(contentsOf: r.illusts)
                nextUrl = r.nextUrl
            }
        case .novel:
            if let r: NovelResponse = try? await api.nextPage(url) {
                novels.append(contentsOf: r.novels)
                nextUrl = r.nextUrl
            }
        }
    }
}

struct RankingDetailView: View {
    @State private var vm: RankingDetailViewModel
    @State private var mute = MuteStore.shared
    @State private var showDatePicker = false
    @Environment(OnboardingStore.self) private var l10n

    init(initialMode: String) {
        _vm = State(wrappedValue: RankingDetailViewModel(initialMode: initialMode))
    }

    private var modes: [String] {
        RankingDetailViewModel.modes(for: vm.kind, includeR18: !mute.hideR18)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { vm.kind },
                set: { newKind in Task { await vm.setKind(newKind) } }
            )) {
                Text(l10n.t(.profileIllusts)).tag(RankingDetailViewModel.Kind.illust)
                Text(l10n.t(.profileManga)).tag(RankingDetailViewModel.Kind.manga)
                Text(l10n.t(.profileNovels)).tag(RankingDetailViewModel.Kind.novel)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(modes, id: \.self) { m in
                        Button {
                            Task { await vm.setMode(m) }
                        } label: {
                            Text(modeName(m))
                                .font(.subheadline.weight(vm.mode == m ? .bold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(vm.mode == m ? Color.accentColor : Color(.secondarySystemBackground),
                                            in: .capsule)
                                .foregroundStyle(vm.mode == m ? Color.white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            // Active past-date banner — upstream never surfaces which day you're
            // viewing; showing it here (with one-tap "back to latest") is a small
            // improvement that keeps the feature discoverable and reversible.
            if let d = vm.date {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                    Text(RankingDetailViewModel.displayDate(d))
                    Spacer()
                    Button(l10n.t(.rankDateLatest)) {
                        Task { await vm.setDate(nil) }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
            }

            if vm.kind == .novel {
                NovelList(
                    novels: vm.novels,
                    isLoading: vm.isLoading,
                    onLoadMore: { await vm.loadMore() },
                    hasMore: vm.nextUrl != nil
                )
                .refreshable { await vm.load() }
                .overlay {
                    if vm.novels.isEmpty, !vm.isLoading, let err = vm.errorMessage {
                        InlineError(message: err) { Task { await vm.load() } }.padding()
                    }
                }
            } else {
                IllustWaterfallList(
                    illusts: vm.illusts,
                    isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onLoadMore: { await vm.loadMore() },
                    hasMore: vm.nextUrl != nil
                )
            }
        }
        .navigationTitle(l10n.t(.rankingTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDatePicker = true
                } label: {
                    // Badge variant signals a past date is active.
                    Image(systemName: vm.date == nil ? "calendar" : "calendar.badge.clock")
                }
            }
        }
        .sheet(isPresented: $showDatePicker) {
            RankDateSheet(
                current: vm.date,
                minDate: RankingDetailViewModel.minDate,
                maxDate: RankingDetailViewModel.maxDate,
                onApply: { d in Task { await vm.setDate(d) } },
                onLatest: { Task { await vm.setDate(nil) } }
            )
        }
        .task { await vm.loadIfNeeded() }
    }

    /// Compose a readable mode label from the localized base term plus
    /// universal R-18/R-18G/AI/Manga markers, avoiding a key per variant.
    private func modeName(_ m: String) -> String {
        var core = m
        var suffixes: [String] = []
        var changed = true
        while changed {
            changed = false
            if core.hasSuffix("_r18g") { suffixes.append("R-18G"); core = String(core.dropLast(5)); changed = true }
            else if core.hasSuffix("_r18") { suffixes.append("R-18"); core = String(core.dropLast(4)); changed = true }
            else if core.hasSuffix("_ai") { suffixes.append("AI"); core = String(core.dropLast(3)); changed = true }
            else if core.hasSuffix("_manga") { suffixes.append(l10n.t(.profileManga)); core = String(core.dropLast(6)); changed = true }
        }
        let base: String
        switch core {
        case "day":           base = l10n.t(.rankModeDay)
        case "week":          base = l10n.t(.rankModeWeek)
        case "month":         base = l10n.t(.rankModeMonth)
        case "day_male":      base = l10n.t(.rankModeDayMale)
        case "day_female":    base = l10n.t(.rankModeDayFemale)
        case "week_rookie":   base = l10n.t(.rankModeWeekRookie)
        case "week_original": base = l10n.t(.rankModeWeekOriginal)
        default:              base = core
        }
        return ([base] + suffixes).joined(separator: " · ")
    }
}

/// Calendar-style date picker sheet for past rankings — the iOS take on
/// upstream `RankActivity`'s `DatePickerDialog` (`setMinDate(2008-01-01)` /
/// `setMaxDate(yesterday)`, future days disabled). "最新一期" clears back to the
/// latest ranking; "应用" commits the picked day. Draft is local so scrubbing
/// the calendar doesn't reload the list until committed.
private struct RankDateSheet: View {
    let current: Date?
    let minDate: Date
    let maxDate: Date
    let onApply: (Date) -> Void
    let onLatest: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n
    @State private var draft: Date

    init(current: Date?, minDate: Date, maxDate: Date,
         onApply: @escaping (Date) -> Void, onLatest: @escaping () -> Void) {
        self.current = current
        self.minDate = minDate
        self.maxDate = maxDate
        self.onApply = onApply
        self.onLatest = onLatest
        _draft = State(initialValue: current ?? maxDate)
    }

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "",
                    selection: $draft,
                    in: minDate...maxDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal)
                Spacer(minLength: 0)
            }
            .navigationTitle(l10n.t(.rankDateTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(l10n.t(.rankDateLatest)) { onLatest(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(l10n.t(.filterApply)) { onApply(draft); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
