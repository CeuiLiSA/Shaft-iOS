import SwiftUI
import UIKit
import WebKit

/// How the search box interprets what you typed — upstream `SearchTypeUtil`.
/// Raw values are the Android indices; `.smart` (5) is the default and guesses
/// URL → numeric ID (illust, then user) → keyword.
enum SearchType: Int, CaseIterable, Identifiable {
    case keyword = 0
    case illustId = 1
    case userId = 2
    case novelId = 3
    case url = 4
    case smart = 5

    static let `default` = SearchType.smart

    var id: Int { rawValue }

    var titleKey: LocalizedKey {
        switch self {
        case .keyword: return .searchTypeKeyword
        case .illustId: return .searchTypeIllustId
        case .userId: return .searchTypeUserId
        case .novelId: return .searchTypeNovelId
        case .url: return .searchTypeUrl
        case .smart: return .searchTypeSmart
        }
    }

    /// `SearchTypeUtil.getSuggestSearchType` — what a piece of clipboard text
    /// most likely is. A bare number above 10,000,000 reads as an illust id,
    /// smaller ones as a user id.
    static func suggested(for content: String) -> SearchType {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .default }
        if SearchInput.isValidURL(trimmed) { return .url }
        if let regex = try? NSRegularExpression(pattern: #"(?:\b|\D)([1-9]\d{3,9})(?:\b|\D)"#),
           let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let r = Range(m.range(at: 1), in: trimmed),
           let number = Int64(trimmed[r]) {
            return number > 10_000_000 ? .illustId : .userId
        }
        return .default
    }
}

/// Small input classifiers shared by the search box (`Common.isNumeric`,
/// `URLUtil.isValidUrl`).
enum SearchInput {
    static func isNumeric(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `URLUtil.isValidUrl`: an http(s)/pixiv scheme with a host.
    static func isValidURL(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https": return !(url.host ?? "").isEmpty
        case "pixiv": return true
        default: return false
        }
    }
}

/// Search landing page — 1:1 port of Pixiv-Shaft `FragmentSearch` /
/// `fragment_search.xml`:
///
/// - header row: pill input (placeholder = current search type,
///   trailing ✕ once there's text) + 「切换」 opening the search-type picker;
/// - 置顶标签 (清空 / 查看全部) → 搜索历史 (清空) → 搜索发现 (first 15 hot tags as
///   `tag/translated` chips), all `TagFlowLayout`-style text chips;
/// - autocomplete overlay for the *last* space-separated word (keyword / smart
///   types only, never for a bare number), tap → search that tag, long-press →
///   replace the last word in the box;
/// - keyword searches are written to history by the results page (upstream
///   `SearchActivity`), ID / URL jumps are written here.
struct SearchView: View {
    @State private var word: String = ""
    @State private var searchType: SearchType = .default
    @State private var hasSwitchedSearchType = false
    @State private var typePickerFromClipboard = false

    @State private var hints: [AutoCompleteTag] = []
    @State private var hintKeyword = ""
    @State private var hintsVisible = false
    @FocusState private var inputFocused: Bool

    @State private var trending: [TrendingTag] = []
    @State private var loadingTrending = false
    @State private var history = SearchHistoryStore.shared
    @State private var pinned = PinnedTagsStore.shared

    /// The one confirmation dialog this page can show at a time — a single
    /// modifier instead of five stacked ones, which SwiftUI does not reliably
    /// honour on the same view.
    @State private var dialog: SearchDialog?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var resolvingSmartId = false

    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.pushRoute) private var pushRoute

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    /// `Params.FRAGMENT_SEARCH_CLIPBOARD_VALUE` — upstream remembers the exact
    /// clipboard string the user already answered the picker for. iOS can't
    /// read the pasteboard without a system prompt, so we remember its
    /// `changeCount` instead, which identifies the same contents just as well.
    private static let confirmedClipboardKey = "fragment_search_clipboard_change_count"

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                landing
                if hintsVisible {
                    hintList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay { if resolvingSmartId { loadingOverlay } }
        .confirmationDialog(
            dialog.map(dialogTitle) ?? "", isPresented: dialogPresented,
            titleVisibility: .visible, presenting: dialog
        ) { dialog in
            dialogButtons(dialog)
        }
        .task { await loadTrendingIfNeeded() }
        .task(id: autocompleteRequest) { await runAutocomplete() }
        .onAppear { predictSearchType() }
        .onChange(of: inputFocused) { _, focused in
            if focused { showHintsIfAvailable() }
        }
    }

    // MARK: Header (top_rela)

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.systemGray))
                TextField(typeLabel(searchType, marked: false), text: $word)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .onTapGesture { inputFocused = true; showHintsIfAvailable() }
                if !word.isEmpty {
                    Button {
                        word = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color(.systemGray2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 36)
            .background(Color(.secondarySystemBackground), in: .capsule)

            Button(l10n.t(.searchSwitchType)) {
                typePickerFromClipboard = false
                dialog = .typePicker
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.brand)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
    }

    private func typeLabel(_ type: SearchType, marked: Bool = true) -> String {
        let name = l10n.t(type.titleKey)
        return marked && type == searchType ? "✓ \(name)" : name
    }

    // MARK: Landing (scroll_view)

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !pinned.tags.isEmpty { pinnedSection }
                if !history.entries.isEmpty { historySection }
                discoverSection
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .contentShape(Rectangle())
        .onTapGesture { hideHints() }
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(l10n.t(.pinnedTagsTitle)) {
                Button(l10n.t(.actionClear)) { dialog = .clearPinned }
                Button(l10n.t(.actionViewAll)) { pushRoute(.pinnedTags) }
            }
            FlowLayout(spacing: 8) {
                ForEach(pinned.tags) { tag in
                    HistoryChip(text: tag.name, pinned: true, onDelete: nil)
                        .onTapGesture { openKeyword(tag.name) }
                        .onLongPressGesture { dialog = .pinnedAction(tag) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(l10n.t(.searchHistoryTitle)) {
                Button(l10n.t(.actionClear)) { dialog = .clearHistory }
            }
            FlowLayout(spacing: 8) {
                ForEach(history.entries) { entry in
                    HistoryChip(text: entry.keyword, pinned: false) {
                        history.remove(entry)
                        showToast(l10n.t(.searchHistoryDeleted))
                    }
                    .onTapGesture { handleHistoryClick(entry) }
                    .onLongPressGesture { dialog = .historyAction(entry) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(l10n.t(.searchDiscoverTitle)) {}
            if trending.isEmpty && loadingTrending {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(trending.prefix(15).enumerated()), id: \.offset) { _, tag in
                        HotTagChip(text: hotTagLabel(tag))
                            .onTapGesture {
                                hideHints()
                                openKeyword(tag.tag ?? "")
                            }
                            .onLongPressGesture { UIPasteboard.general.string = tag.tag ?? "" }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func hotTagLabel(_ tag: TrendingTag) -> String {
        let name = tag.tag ?? ""
        if let t = tag.translatedName, !t.isEmpty { return "\(name)/\(t)" }
        return name
    }

    /// 14sp `second_text_color` title, `colorPrimary` 14sp actions on the right;
    /// 24pt above, 8pt below (fragment_search.xml section headers).
    private func sectionHeader<Actions: View>(
        _ title: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(SearchChipStyle.text)
            Spacer()
            actions()
                .font(.system(size: 14))
                .foregroundStyle(Theme.brand)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    // MARK: Hint list (hint_list)

    private var hintList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(hints) { tag in
                    SearchHintRow(tag: tag, keyword: hintKeyword)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            hideHints()
                            openKeyword(tag.name ?? "")
                        }
                        .onLongPressGesture { replaceLastWord(with: tag.name ?? "") }
                }
            }
        }
        .background(Color(.systemBackground))
    }

    /// Long-press on a hint swaps the word being typed for the full tag and
    /// leaves a trailing space so the next word starts clean.
    private func replaceLastWord(with tagName: String) {
        hideHints()
        var keys = word.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if keys.isEmpty {
            keys = [tagName]
        } else {
            keys[keys.count - 1] = tagName
        }
        word = keys.joined(separator: " ") + " "
    }

    // MARK: Autocomplete

    /// The word the autocomplete request is keyed on, or nil when upstream's
    /// `shouldAutocomplete` says no (empty, trailing space, wrong search type,
    /// or a bare number in smart mode).
    private var autocompleteRequest: String? {
        guard !word.isEmpty, !word.hasSuffix(" ") else { return nil }
        let allowed = searchType == .keyword
            || (searchType == .smart && !SearchInput.isNumeric(word))
        guard allowed else { return nil }
        return word.split(separator: " ").last.map(String.init)
    }

    private func runAutocomplete() async {
        guard let lastWord = autocompleteRequest, !lastWord.isEmpty else {
            clearHints()
            return
        }
        // SearchHintViewModel.DEBOUNCE_MS
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        do {
            let list = try await api.autocompleteTags(prefix: lastWord).tags
            guard !Task.isCancelled else { return }
            hints = list
            hintKeyword = lastWord
            setHintsVisible(!list.isEmpty)
        } catch {
            guard !Task.isCancelled else { return }
            setHintsVisible(false)
        }
    }

    private func clearHints() {
        hints = []
        hintKeyword = ""
        setHintsVisible(false)
    }

    private func hideHints() { setHintsVisible(false) }

    private func showHintsIfAvailable() {
        if !hints.isEmpty { setHintsVisible(true) }
    }

    private func setHintsVisible(_ visible: Bool) {
        guard hintsVisible != visible else { return }
        withAnimation(visible ? .easeOut(duration: 0.22) : .easeIn(duration: 0.16)) {
            hintsVisible = visible
        }
    }

    // MARK: Dispatch (dispatchClick)

    private func submit() {
        guard !word.isEmpty else {
            showToast(l10n.t(.searchEmptyInput))
            return
        }
        inputFocused = false
        dispatch(word, type: searchType)
    }

    private func dispatch(_ keyword: String, type: SearchType) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .keyword:
            hideHints()
            openKeyword(kw)
        case .illustId:
            guard SearchInput.isNumeric(kw), let id = Int64(kw) else {
                showToast(l10n.t(.searchIdNumericOnly)); return
            }
            history.record(kw, kind: .illustId)
            pushRoute(.illustDetail(id))
        case .userId:
            guard SearchInput.isNumeric(kw), let id = Int64(kw) else {
                showToast(l10n.t(.searchIdNumericOnly)); return
            }
            history.record(kw, kind: .userId)
            pushRoute(.userProfile(id))
        case .novelId:
            guard SearchInput.isNumeric(kw), let id = Int64(kw) else {
                showToast(l10n.t(.searchIdNumericOnly)); return
            }
            history.record(kw, kind: .novelId)
            pushRoute(.novelDetail(id))
        case .url:
            guard SearchInput.isValidURL(kw) else {
                showToast(l10n.t(.searchInvalidUrl)); return
            }
            history.record(kw, kind: .url)
            openURL(kw)
        case .smart:
            if SearchInput.isValidURL(kw) {
                history.record(kw, kind: .url)
                openURL(kw)
            } else if SearchInput.isNumeric(kw), let id = Int64(kw) {
                resolveSmartId(id, raw: kw)
            } else {
                hideHints()
                openKeyword(kw)
            }
        }
    }

    /// Smart mode with a bare number: assume an illust id first; if pixiv says
    /// no such work, fall back to treating it as a user id (upstream
    /// `PixivOperate.getIllustByID` success / failure callbacks).
    private func resolveSmartId(_ id: Int64, raw: String) {
        guard !resolvingSmartId else { return }
        resolvingSmartId = true
        Task { @MainActor in
            defer { resolvingSmartId = false }
            do {
                _ = try await api.illustDetail(id)
                history.record(raw, kind: .illustId)
                pushRoute(.illustDetail(id))
            } catch {
                history.record(raw, kind: .userId)
                pushRoute(.userProfile(id))
            }
        }
    }

    /// `OutWakeActivity` — a pixiv link resolves to its in-app page; anything
    /// else opens in the in-app web page.
    private func openURL(_ raw: String) {
        if let route = PixivLinkParser.shortcuts(for: raw).first?.route {
            pushRoute(route)
        } else {
            pushRoute(.webArticle(url: raw))
        }
    }

    private func openKeyword(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        pushRoute(.searchResults(word: kw))
    }

    /// `handleHistoryClick` — replay the row the way it was originally searched.
    private func handleHistoryClick(_ entry: SearchHistoryEntry) {
        switch entry.kind {
        case .keyword, .userKeyword:
            hideHints()
            openKeyword(entry.keyword)
        case .illustId:
            history.record(entry.keyword, kind: .illustId)
            if let id = Int64(entry.keyword) { pushRoute(.illustDetail(id)) }
        case .userId:
            history.record(entry.keyword, kind: .userId)
            if let id = Int64(entry.keyword) { pushRoute(.userProfile(id)) }
        case .novelId:
            history.record(entry.keyword, kind: .novelId)
            if let id = Int64(entry.keyword) { pushRoute(.novelDetail(id)) }
        case .url:
            history.record(entry.keyword, kind: .url)
            openURL(entry.keyword)
        }
    }

    // MARK: Pin / unpin (showHistoryActionDialog)

    /// Toggling `pinned` on a row moves it between the two sections.
    private func pinFromHistory(_ entry: SearchHistoryEntry) {
        pinned.pin(name: entry.keyword, translatedName: nil)
        history.remove(entry)
    }

    private func unpinToHistory(_ tag: PinnedTag) {
        pinned.unpin(tag.name)
        history.record(tag.name, kind: .keyword)
    }

    // MARK: Dialogs

    enum SearchDialog: Identifiable {
        case typePicker
        case clearHistory
        case clearPinned
        case historyAction(SearchHistoryEntry)
        case pinnedAction(PinnedTag)

        var id: String {
            switch self {
            case .typePicker: return "type"
            case .clearHistory: return "clearHistory"
            case .clearPinned: return "clearPinned"
            case .historyAction(let e): return "history:\(e.id)"
            case .pinnedAction(let t): return "pinned:\(t.id)"
            }
        }
    }

    private var dialogPresented: Binding<Bool> {
        Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } })
    }

    private func dialogTitle(_ dialog: SearchDialog) -> String {
        switch dialog {
        case .typePicker:
            return l10n.t(typePickerFromClipboard ? .searchChooseTypeClipboard : .searchChooseType)
        case .clearHistory: return l10n.t(.searchClearHistoryMessage)
        case .clearPinned: return l10n.t(.pinnedClearMessage)
        case .historyAction(let entry): return entry.keyword
        case .pinnedAction(let tag): return tag.name
        }
    }

    @ViewBuilder
    private func dialogButtons(_ dialog: SearchDialog) -> some View {
        switch dialog {
        case .typePicker:
            ForEach(SearchType.allCases) { type in
                Button(typeLabel(type)) { pickSearchType(type) }
            }
        case .clearHistory:
            Button(l10n.t(.actionDelete), role: .destructive) {
                history.clear()
                showToast(l10n.t(.searchHistoryCleared))
            }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        case .clearPinned:
            Button(l10n.t(.actionDelete), role: .destructive) {
                pinned.clear()
                showToast(l10n.t(.pinnedTagsCleared))
            }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        case .historyAction(let entry):
            Button(l10n.t(.actionPinTag)) { pinFromHistory(entry) }
            Button(l10n.t(.actionCopy)) { UIPasteboard.general.string = entry.keyword }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        case .pinnedAction(let tag):
            Button(l10n.t(.actionUnpinTag)) { unpinToHistory(tag) }
            Button(l10n.t(.actionCopy)) { UIPasteboard.general.string = tag.name }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
    }

    // MARK: Search type picker (popUpSearchTypeSwitcher / predictSearchType)

    private func pickSearchType(_ type: SearchType) {
        searchType = type
        if typePickerFromClipboard {
            UserDefaults.standard.set(UIPasteboard.general.changeCount,
                                      forKey: Self.confirmedClipboardKey)
            // Upstream pre-fills the box for anything but keyword / smart search.
            if type != .keyword, type != .default,
               let content = UIPasteboard.general.string?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                word = content
            }
        }
    }

    /// On appear, peek at the pasteboard (pattern detection only — no paste
    /// prompt) and, if it looks like a URL or an ID, pre-select that search
    /// type and ask the user to confirm. Once per page instance, never while
    /// there's already text, and never twice for the same clipboard contents.
    private func predictSearchType() {
        guard !hasSwitchedSearchType, word.isEmpty else { return }
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings || pasteboard.hasURLs else { return }
        let confirmed = UserDefaults.standard.integer(forKey: Self.confirmedClipboardKey)
        guard pasteboard.changeCount != confirmed else { return }
        Task { @MainActor in
            let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [
                \.probableWebURL, \.number,
            ]
            guard let found = try? await pasteboard.detectedPatterns(for: patterns),
                  !found.isEmpty,
                  !hasSwitchedSearchType, word.isEmpty else { return }
            // Pattern detection can't tell an illust id from a user id
            // (upstream splits at 10,000,000) and reading the text here would
            // raise the system paste prompt before the user agreed to
            // anything — so a bare number is offered as an illust id and the
            // picker lets them correct it.
            let suggested: SearchType = found.contains(\.probableWebURL) ? .url : .illustId
            guard suggested != searchType else { return }
            searchType = suggested
            hasSwitchedSearchType = true
            typePickerFromClipboard = true
            dialog = .typePicker
        }
    }

    // MARK: Toast / loading

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast {
            Text(toast)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: .capsule)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(l10n.t(.searchLoading))
                .font(.subheadline)
                .foregroundStyle(.white)
        }
        .padding(24)
        .background(Color.black.opacity(0.72), in: .rect(cornerRadius: 12))
    }

    // MARK: Loading

    private func loadTrendingIfNeeded() async {
        guard trending.isEmpty, !loadingTrending else { return }
        loadingTrending = true
        defer { loadingTrending = false }
        trending = (try? await api.trendingTags())?.trendTags ?? []
    }
}

// MARK: - Chips

/// `normal_bg` (#f4f4f4 / #434343, 3dp corners) + `second_text_color`
/// (#333333 / #8E8E8E) — the palette of the search page's text chips.
enum SearchChipStyle {
    static let fill = Color(light: 0xF4F4F4, dark: 0x434343)
    static let text = Color(light: 0x333333, dark: 0x8E8E8E)
    static let corner: CGFloat = 3
}

/// `recy_single_line_text_with_delete`: 8dp padding, pin icon leading for
/// pinned rows, ✕ trailing (deletes) for recent rows.
private struct HistoryChip: View {
    let text: String
    let pinned: Bool
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(SearchChipStyle.text)
                    .frame(width: 16, height: 16)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(SearchChipStyle.text)
                .lineLimit(1)
            if !pinned, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(SearchChipStyle.text)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(SearchChipStyle.fill, in: .rect(cornerRadius: SearchChipStyle.corner))
        .contentShape(Rectangle())
    }
}

/// `recy_single_line_text`: 12dp horizontal / 8dp vertical, 13sp.
private struct HotTagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(SearchChipStyle.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SearchChipStyle.fill, in: .rect(cornerRadius: SearchChipStyle.corner))
            .contentShape(Rectangle())
    }
}

/// `recy_search_hint`: tag name (typed part tinted `colorPrimary`) on the left,
/// `译：<translated>` on the right when it differs, 1dp inset divider below.
private struct SearchHintRow: View {
    let tag: AutoCompleteTag
    let keyword: String
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(highlighted)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let t = tag.translatedName, !t.isEmpty, t != tag.name {
                    Text(l10n.t(.searchHintTranslatedFmt, t))
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().padding(.horizontal, 12)
        }
    }

    private var highlighted: AttributedString {
        let name = tag.name ?? ""
        var attributed = AttributedString(name)
        guard !keyword.isEmpty else { return attributed }
        var searchRange = name.startIndex..<name.endIndex
        while let found = name.range(of: keyword, options: [.caseInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: attributed),
               let upper = AttributedString.Index(found.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = Theme.brand
            }
            searchRange = found.upperBound..<name.endIndex
        }
        return attributed
    }
}

/// Parses Pixiv URLs and bare numeric IDs into navigation shortcuts that
/// surface above tag suggestions in the search box.
enum PixivLinkParser {
    struct Shortcut {
        let title: String
        let systemImage: String
        let route: AppRoute
    }

    static func shortcuts(for input: String) -> [Shortcut] {
        guard !input.isEmpty else { return [] }

        // Pixiv app scheme: pixiv://artworks/123, pixiv://users/123
        if let url = URL(string: input), url.scheme?.lowercased() == "pixiv" {
            if let id = numericID(in: url.path) ?? numericID(in: url.host ?? "") {
                let host = (url.host ?? "").lowercased()
                if host.contains("user") {
                    return [Shortcut(title: "User \(id)", systemImage: "person.crop.circle", route: .userProfile(id))]
                }
                if host.contains("novel") {
                    return [Shortcut(title: "Novel \(id)", systemImage: "book", route: .novelDetail(id))]
                }
                return [Shortcut(title: "Illust \(id)", systemImage: "photo", route: .illustDetail(id))]
            }
        }

        // Web URLs.
        let lower = input.lowercased()
        if lower.contains("pixiv.net") {
            if let r = match(input, "/artworks/(\\d+)") { return [.init(title: "Illust \(r)", systemImage: "photo", route: .illustDetail(r))] }
            if let r = match(input, "/i/(\\d+)")        { return [.init(title: "Illust \(r)", systemImage: "photo", route: .illustDetail(r))] }
            if let r = match(input, "/users/(\\d+)")    { return [.init(title: "User \(r)", systemImage: "person.crop.circle", route: .userProfile(r))] }
            if let r = match(input, "/member.php\\?id=(\\d+)") { return [.init(title: "User \(r)", systemImage: "person.crop.circle", route: .userProfile(r))] }
            if let r = match(input, "/novel/show.php\\?id=(\\d+)") { return [.init(title: "Novel \(r)", systemImage: "book", route: .novelDetail(r))] }
            if let r = match(input, "/n/(\\d+)")        { return [.init(title: "Novel \(r)", systemImage: "book", route: .novelDetail(r))] }
        }

        // Bare numeric ID — type ambiguous, offer all three.
        if let id = Int64(input), id > 0 {
            return [
                .init(title: "Illust \(id)", systemImage: "photo",            route: .illustDetail(id)),
                .init(title: "User \(id)",   systemImage: "person.crop.circle", route: .userProfile(id)),
                .init(title: "Novel \(id)",  systemImage: "book",            route: .novelDetail(id)),
            ]
        }
        return []
    }

    /// Compiled once — `shortcuts(for:)` runs in the search List's body on
    /// every keystroke, and NSRegularExpression compilation isn't free.
    private static let compiledPatterns: [String: NSRegularExpression] = {
        let patterns = [
            "/artworks/(\\d+)", "/i/(\\d+)", "/users/(\\d+)",
            "/member.php\\?id=(\\d+)", "/novel/show.php\\?id=(\\d+)", "/n/(\\d+)",
        ]
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { p in
            (try? NSRegularExpression(pattern: p)).map { (p, $0) }
        })
    }()

    private static func match(_ input: String, _ pattern: String) -> Int64? {
        guard let regex = compiledPatterns[pattern] else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let m = regex.firstMatch(in: input, range: range), m.numberOfRanges >= 2 else { return nil }
        guard let r = Range(m.range(at: 1), in: input) else { return nil }
        return Int64(input[r])
    }

    private static func numericID(in s: String) -> Int64? {
        let digits = s.split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? ""
        return Int64(digits)
    }
}

@MainActor
@Observable
final class SearchResultsViewModel {
    let word: String

    /// Displayed (post client-side filter) results. Raw pages are retained so
    /// pagination and client-only filters always use the frozen generation.
    var illusts: [Illust] = []
    var novelItems: [SearchNovelItem] = []
    var users: [UserPreview] = []
    @ObservationIgnored private var rawIllusts: [Illust] = []
    @ObservationIgnored private var rawNovelItems: [SearchNovelItem] = []
    @ObservationIgnored private var rawUsers: [UserPreview] = []
    @ObservationIgnored private var illustGeneration = 0
    @ObservationIgnored private var novelGeneration = 0
    @ObservationIgnored private var userGeneration = 0
    @ObservationIgnored private var illustHasLoaded = false
    @ObservationIgnored private var novelHasLoaded = false
    @ObservationIgnored private var userHasLoaded = false
    @ObservationIgnored private var illustLoadTask: Task<Void, Never>?
    @ObservationIgnored private var novelLoadTask: Task<Void, Never>?
    @ObservationIgnored private var userLoadTask: Task<Void, Never>?
    /// Filters backing the currently displayed generation. The sheet's live
    /// state can change without a refresh when its parent Cancel is tapped.
    @ObservationIgnored private var illustResultsFilter: SearchFilter
    @ObservationIgnored private var novelResultsFilter: SearchFilter
    /// `gs=1` pagination must keep the first page's frozen parameters.
    @ObservationIgnored private var groupedNovelFilter: SearchFilter?

    var illustNext: String?
    var novelNext: String?
    var userNext: String?

    /// Shaft keeps independent live filters for illustration and novel tabs.
    /// Changing one tab must not silently mutate the other tab's query.
    var illustFilter: SearchFilter
    var novelFilter: SearchFilter
    /// Dynamic tool / genre / language options, loaded once.
    var options: SearchOptionsResponse?
    /// Refreshed from the authoritative self profile before every generation.
    var isPremium = false
    var novelResultsGrouped = false
    var novelWebAuthenticated = false

    var isLoadingIllust = false
    var isLoadingNovel = false
    var isLoadingUsers = false
    var isLoadingMoreIllusts = false
    var isLoadingMoreNovels = false
    var isLoadingMoreUsers = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI
    @ObservationIgnored private let requests: SearchRequestCoordinator

    init(word: String) {
        self.word = word
        let illustDefault = SearchFilter.makeDefault()
        let novelDefault = SearchFilter.makeDefault(forNovel: true)
        self.illustFilter = illustDefault
        self.novelFilter = novelDefault
        self.illustResultsFilter = illustDefault
        self.novelResultsFilter = novelDefault
        self.groupedNovelFilter = nil
        self.isPremium = KeychainTokenStore.shared.load()?.user?.isPremium ?? false
        let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
        self.api = api
        self.requests = SearchRequestCoordinator(api: api)
    }

    /// Upstream's off-screen ViewPager pages do not search until they are first
    /// resumed. That distinction matters for borrowed popularity searches: an
    /// initial illustration page must not silently consume a second novel slot.
    func loadIllustIfNeeded() async {
        guard !illustHasLoaded else { return }
        await reloadIllust()
    }

    func loadNovelIfNeeded() async {
        guard !novelHasLoaded else { return }
        await reloadNovel()
    }

    func loadUsersIfNeeded() async {
        guard !userHasLoaded else { return }
        await reloadUsers()
    }

    func loadOptionsIfNeeded() async {
        guard options == nil else { return }
        // The response is word-independent but pixiv requires a non-empty word.
        // Upstream uses this harmless placeholder when a query should not be
        // leaked merely by opening the filter sheet.
        options = try? await api.searchOptions(word: "art")
    }

    /// Resolves premium status (self id → user detail) so popular sorts route
    /// correctly. Best-effort; defaults to non-premium until known.
    func refreshAccount() async {
        guard let uid = try? await api.selfProfile().profile.userId else {
            return
        }
        if let detail = try? await api.userDetail(uid) {
            if let premium = detail.profile?.isPremium { isPremium = premium }
        }
    }

    /// Apply only to the tab that opened the sheet, matching the two LiveData
    /// stores and two refresh events in Pixiv-Shaft's SearchViewModel.
    func apply(_ newFilter: SearchFilter, isNovel: Bool) async {
        if isNovel {
            novelFilter = newFilter
            await startNovelGeneration(filter: newFilter, clearCurrent: true)
        } else {
            illustFilter = newFilter
            await startIllustGeneration(filter: newFilter, clearCurrent: true)
        }
    }

    /// Child pickers commit into shared filter state immediately, while the
    /// displayed generation remains untouched until Search is pressed.
    func stage(_ newFilter: SearchFilter, isNovel: Bool) {
        if isNovel { novelFilter = newFilter }
        else { illustFilter = newFilter }
    }

    func reloadIllust() async {
        await startIllustGeneration(filter: illustFilter, clearCurrent: false)
    }

    func reloadNovel() async {
        await startNovelGeneration(filter: novelFilter, clearCurrent: false)
    }

    func reloadUsers() async {
        userHasLoaded = true
        userGeneration += 1
        let generation = userGeneration
        userLoadTask?.cancel()
        isLoadingUsers = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performUserGeneration(generation: generation)
        }
        userLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performUserGeneration(generation: Int) async {
        defer {
            if userGeneration == generation { isLoadingUsers = false }
        }
        do {
            let response = try await api.searchUser(word: word)
            guard userGeneration == generation else { return }
            rawUsers = response.userPreviews
            userNext = response.nextUrl
            recomputeUsers()
        } catch {
            if userGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    private func startIllustGeneration(filter: SearchFilter, clearCurrent: Bool) async {
        illustHasLoaded = true
        illustGeneration += 1
        let generation = illustGeneration
        illustLoadTask?.cancel()
        illustResultsFilter = filter
        if clearCurrent {
            rawIllusts = []; illusts = []; illustNext = nil
        }
        isLoadingIllust = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performIllustGeneration(filter: filter, generation: generation)
        }
        illustLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performIllustGeneration(filter: SearchFilter, generation: Int) async {
        defer {
            if illustGeneration == generation { isLoadingIllust = false }
        }
        // Membership is deliberately re-read at the start of every result
        // generation. A stale login snapshot must never decide whether to use
        // the signed-in token or a borrowed Premium account.
        await refreshAccount()
        guard illustGeneration == generation else { return }
        await requests.startIllustGeneration()
        guard illustGeneration == generation else { return }
        let requesterUID = KeychainTokenStore.shared.load()?.user?.id ?? 0
        do {
            let response = try await requests.firstIllust(
                word: word, filter: filter,
                requesterUID: requesterUID, isPremium: isPremium
            )
            guard illustGeneration == generation else { return }
            rawIllusts = response.illusts
            illustNext = response.nextUrl
            recomputeIllusts()
        } catch {
            if illustGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    private func startNovelGeneration(filter: SearchFilter, clearCurrent: Bool) async {
        novelHasLoaded = true
        novelGeneration += 1
        let generation = novelGeneration
        novelLoadTask?.cancel()
        novelResultsFilter = filter
        groupedNovelFilter = filter.groupBySeries ? filter : nil
        novelResultsGrouped = filter.groupBySeries
        if !filter.groupBySeries { novelWebAuthenticated = false }
        if clearCurrent {
            rawNovelItems = []; novelItems = []; novelNext = nil
        }
        isLoadingNovel = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performNovelGeneration(filter: filter, generation: generation)
        }
        novelLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performNovelGeneration(filter: SearchFilter, generation: Int) async {
        defer {
            if novelGeneration == generation { isLoadingNovel = false }
        }
        if !filter.groupBySeries {
            // Grouped mode is a web-cookie request. App OAuth membership and
            // the borrowed-session coordinator do not participate in it.
            await refreshAccount()
            guard novelGeneration == generation else { return }
            await requests.startNovelGeneration()
            guard novelGeneration == generation else { return }
        }
        let requesterUID = KeychainTokenStore.shared.load()?.user?.id ?? 0
        do {
            if filter.groupBySeries {
                let page = try await GroupedNovelSearchClient.shared.search(
                    word: word, filter: filter, page: 1
                )
                guard novelGeneration == generation else { return }
                rawNovelItems = page.items
                novelNext = page.nextPage.map { "grouped:\($0)" }
                novelWebAuthenticated = page.webAuthenticated
            } else {
                let response = try await requests.firstNovel(
                    word: word, filter: filter,
                    requesterUID: requesterUID, isPremium: isPremium
                )
                guard novelGeneration == generation else { return }
                rawNovelItems = response.novels.map(SearchNovelItem.novel)
                novelNext = response.nextUrl
            }
            recomputeNovels()
        } catch {
            if novelGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    func loadMoreIllusts() async {
        guard let url = illustNext, !isLoadingMoreIllusts else { return }
        let generation = illustGeneration
        isLoadingMoreIllusts = true
        defer { isLoadingMoreIllusts = false }
        if let r = try? await requests.nextIllust(url) {
            guard illustGeneration == generation else { return }
            rawIllusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
            recomputeIllusts()
        }
    }

    func loadMoreNovels() async {
        guard let url = novelNext, !isLoadingMoreNovels else { return }
        let generation = novelGeneration
        isLoadingMoreNovels = true
        defer { isLoadingMoreNovels = false }
        if let groupedFilter = groupedNovelFilter,
           url.hasPrefix("grouped:"),
           let pageNumber = Int(url.dropFirst("grouped:".count)) {
            if let page = try? await GroupedNovelSearchClient.shared.search(
                word: word, filter: groupedFilter, page: pageNumber
            ) {
                guard novelGeneration == generation else { return }
                rawNovelItems.append(contentsOf: page.items)
                novelNext = page.nextPage.map { "grouped:\($0)" }
                novelWebAuthenticated = page.webAuthenticated
                recomputeNovels()
            }
        } else if let r = try? await requests.nextNovel(url) {
            guard novelGeneration == generation else { return }
            rawNovelItems.append(contentsOf: r.novels.map(SearchNovelItem.novel))
            novelNext = r.nextUrl
            recomputeNovels()
        }
    }

    func loadMoreUsers() async {
        guard let url = userNext, !isLoadingMoreUsers else { return }
        let generation = userGeneration
        isLoadingMoreUsers = true
        defer { isLoadingMoreUsers = false }
        if let r: UserPreviewResponse = try? await api.nextPage(url) {
            guard userGeneration == generation else { return }
            rawUsers.append(contentsOf: r.userPreviews)
            userNext = r.nextUrl
            recomputeUsers()
        }
    }

    // MARK: Client-side filtering
    //
    // The normal mute/global-R18 chain remains active, then search's real
    // `x_restrict` and AI modes narrow it further. This deliberately means a
    // global R-18 block still wins over search's “R-18 only” choice, as in Mapper.

    private func recomputeIllusts() {
        illusts = MuteStore.shared.filter(rawIllusts, applyR18: true)
            .filter { illustResultsFilter.accepts($0) }
    }

    private func recomputeNovels() {
        novelItems = rawNovelItems.filter { item in
            !MuteStore.shared.filter([item.novel], applyR18: true).isEmpty &&
                novelResultsFilter.accepts(item.novel)
        }
    }

    private func recomputeUsers() {
        users = rawUsers.filter { !MuteStore.shared.isUserMuted($0.user.id) }
    }
}

struct SearchResultsView: View {
    let word: String
    @State private var vm: SearchResultsViewModel
    @State private var section: Section = .illust
    @State private var showFilter = false
    @State private var showWebLogin = false
    @State private var showUserFilterHint = false
    @State private var historyRecorded = false
    @State private var quotaNotices = BorrowedQuotaNoticeStore.shared
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case illust, novel, user }

    init(word: String, initialSection: String = "illust") {
        self.word = word
        _vm = State(wrappedValue: SearchResultsViewModel(word: word))
        switch initialSection {
        case "novel": _section = State(wrappedValue: .novel)
        case "user":  _section = State(wrappedValue: .user)
        default:      _section = State(wrappedValue: .illust)
        }
    }

    /// Active dimensions on the tab currently in view, for the toolbar badge.
    private var activeCount: Int {
        switch section {
        case .novel: return vm.novelFilter.activeCount(isNovel: true)
        case .illust: return vm.illustFilter.activeCount(isNovel: false)
        case .user: return 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: Section.allCases.map { ($0, label(for: $0)) },
                selection: $section
            )
            TabView(selection: $section) {
                IllustWaterfallList(
                    illusts: vm.illusts, isLoading: vm.isLoadingIllust,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.reloadIllust() },
                    onLoadMore: { await vm.loadMoreIllusts() },
                    hasMore: vm.illustNext != nil,
                    prefiltered: true
                ).tag(Section.illust)
                SearchNovelList(
                    items: vm.novelItems,
                    isLoading: vm.isLoadingNovel,
                    grouped: vm.novelResultsGrouped,
                    webAuthenticated: vm.novelWebAuthenticated,
                    onWebLogin: { showWebLogin = true },
                    onLoadMore: { await vm.loadMoreNovels() },
                    hasMore: vm.novelNext != nil
                ).tag(Section.novel)
                UserPreviewList(
                    items: vm.users,
                    isLoading: vm.isLoadingUsers,
                    onLoadMore: { await vm.loadMoreUsers() },
                    hasMore: vm.userNext != nil
                ).tag(Section.user)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("\u{201C}\(word)\u{201D}")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // Upstream keeps the icon on the author tab and emits a
                    // short toast instead of opening an illustration filter.
                    guard section != .user else {
                        withAnimation { showUserFilterHint = true }
                        Task { @MainActor in
                            do { try await Task.sleep(for: .seconds(2)) }
                            catch { return }
                            withAnimation { showUserFilterHint = false }
                        }
                        return
                    }
                    Task { await vm.loadOptionsIfNeeded() }
                    showFilter = true
                } label: {
                    Image(systemName: activeCount > 0
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .overlay(alignment: .topTrailing) {
                            if activeCount > 0 {
                                Text("\(activeCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Theme.brand, in: .circle)
                                    .offset(x: 8, y: -8)
                            }
                        }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = quotaNotices.notice {
                HStack(spacing: 12) {
                    Text(quotaMessage(notice))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        withAnimation { quotaNotices.consume(id: notice.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.v3CardHairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    do { try await Task.sleep(for: .seconds(12)) }
                    catch { return }
                    withAnimation { quotaNotices.consume(id: notice.id) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showUserFilterHint {
                Text(l10n.t(.filterUserUnsupported))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                    .padding(.bottom, quotaNotices.notice == nil ? 12 : 82)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showFilter) {
            let isNovel = section == .novel
            SearchFilterSheet(
                filter: isNovel ? vm.novelFilter : vm.illustFilter,
                options: vm.options,
                isNovelTab: isNovel,
                onChange: { vm.stage($0, isNovel: isNovel) },
                onReloadOptions: { Task { await vm.loadOptionsIfNeeded() } }
            ) { newFilter in
                await vm.apply(newFilter, isNovel: isNovel)
            }
        }
        .sheet(isPresented: $showWebLogin, onDismiss: {
            guard section == .novel, vm.novelResultsGrouped else { return }
            Task { await vm.reloadNovel() }
        }) {
            PixivWebLoginSheet()
        }
        .task {
            // Upstream SearchActivity is the single writer of keyword history:
            // every entry (chip, hint, hot tag, typed) lands here first. Once
            // per page — `.task` re-runs when we pop back from a detail page.
            if !historyRecorded {
                historyRecorded = true
                SearchHistoryStore.shared.record(word, kind: .keyword)
            }
            await vm.loadIllustIfNeeded()
        }
        .onChange(of: section) { _, value in
            Task { @MainActor in
                switch value {
                case .illust: await vm.loadIllustIfNeeded()
                case .novel: await vm.loadNovelIfNeeded()
                case .user: await vm.loadUsersIfNeeded()
                }
            }
        }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        case .user:   return l10n.t(.searchTabUser)
        }
    }

    private func quotaMessage(_ notice: BorrowedQuotaNotice) -> String {
        let totalMinutes = (notice.resetInMS + 59_999) / 60_000
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        let duration: String
        if days > 0 {
            duration = l10n.t(.borrowQuotaDaysHoursFmt, "\(days)", "\(hours)")
        } else if hours > 0 {
            duration = l10n.t(.borrowQuotaHoursMinutesFmt, "\(hours)", "\(minutes)")
        } else {
            duration = l10n.t(.borrowQuotaMinutesFmt, "\(minutes)")
        }
        return l10n.t(
            notice.scope == "uid_weekly" ? .borrowQuotaWeeklyFmt : .borrowQuotaSessionFmt,
            duration
        )
    }
}

/// Search uses a destination-bearing wrapper because the grouped web endpoint
/// returns a mixed list: a row can be either one novel or one whole series.
/// Feeding a series id into the novel-detail route would produce a 404.
private struct SearchNovelList: View {
    let items: [SearchNovelItem]
    let isLoading: Bool
    let grouped: Bool
    let webAuthenticated: Bool
    let onWebLogin: () -> Void
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ScrollView {
            if items.isEmpty, isLoading {
                NovelListSkeleton()
            } else if items.isEmpty, grouped {
                ContentUnavailableView {
                    Label(l10n.t(.filterGroupBySeries), systemImage: "books.vertical")
                } description: {
                    Text(webAuthenticated ? l10n.t(.nothingHere) : l10n.t(.searchSeriesEmptyHint))
                } actions: {
                    if !webAuthenticated {
                        Button(l10n.t(.filterWebLogin), action: onWebLogin)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        NavigationLink(value: item.destination) {
                            VStack(alignment: .leading, spacing: 0) {
                                NovelRow(novel: item.novel)
                                if let count = item.episodeCount {
                                    Text(l10n.t(
                                        item.isConcluded == true
                                            ? .searchSeriesConcludedFmt
                                            : .searchSeriesOngoingFmt,
                                        "\(count)"
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 108)
                                    .padding(.bottom, 8)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .novelCardMenu(novel: item.novel) { items.map(\.novel) }
                    }
                    if hasMore, !items.isEmpty {
                        Color.clear
                            .frame(height: 40)
                            .onAppear { Task { await onLoadMore?() } }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .cardMenuHost()
    }
}

private struct PixivWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationStack {
            PixivWebLoginView(url: URL(string: "https://www.pixiv.net/")!)
                .navigationTitle(l10n.t(.filterWebLogin))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(l10n.t(.actionDone)) { dismiss() }
                    }
                }
        }
    }
}

private struct PixivWebLoginView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct UserPreviewList: View {
    let items: [UserPreview]
    let isLoading: Bool
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool

    init(
        items: [UserPreview],
        isLoading: Bool = false,
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false
    ) {
        self.items = items
        self.isLoading = isLoading
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
    }

    var body: some View {
        ScrollView {
            if items.isEmpty, isLoading {
                UserListSkeleton()
            } else {
            LazyVStack(spacing: 12) {
                ForEach(items) { preview in
                    NavigationLink(value: AppRoute.userProfile(preview.user.id)) {
                        UserPreviewRow(preview: preview)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if hasMore, !items.isEmpty {
                    Color.clear
                        .frame(height: 40)
                        .onAppear { Task { await onLoadMore?() } }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

struct UserPreviewRow: View {
    let preview: UserPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PixivAsyncImage(url: avatar)
                    .frame(width: 48, height: 48)
                    .clipShape(.circle)
                VStack(alignment: .leading) {
                    Text(preview.user.name ?? "").font(.subheadline.bold())
                    Text("@\(preview.user.account ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let illusts = preview.illusts, !illusts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(illusts.prefix(3).enumerated()), id: \.offset) { _, i in
                        PixivAsyncImage(url: thumb(i))
                            .aspectRatio(1, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 100)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var avatar: URL? {
        (preview.user.profileImageUrls?.medium ?? preview.user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }

    private func thumb(_ illust: Illust) -> URL? {
        let s = illust.imageUrls?.squareMedium ?? illust.imageUrls?.medium
        return s.flatMap(URL.init(string:))
    }
}
