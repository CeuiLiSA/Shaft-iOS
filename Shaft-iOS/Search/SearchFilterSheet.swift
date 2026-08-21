import SwiftUI

/// Pixel-for-pixel iOS projection of Pixiv-Shaft 4.8.7's V3 filter hierarchy:
/// a compact top bar, three rounded settings cards and a full-width search pill.
/// Every row opens the same single-choice or range editor used by the Android
/// implementation. Confirmed child-picker changes are retained immediately;
/// only the bottom button triggers a new search, exactly like the shared
/// SearchViewModel state in Pixiv-Shaft.
struct SearchFilterSheet: View {
    @State private var draft: SearchFilter
    @State private var editor: Editor?
    @State private var pendingEditor: Editor?
    /// Freeze the dynamic bookmark rows for the lifetime of one picker. The
    /// options response may arrive while that picker is visible.
    @State private var bookmarkPresetsShown: [BookmarkRange]?

    let options: SearchOptionsResponse?
    let isNovelTab: Bool
    let onChange: (SearchFilter) -> Void
    let onReloadOptions: () -> Void
    let onApply: (SearchFilter) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    init(
        filter: SearchFilter,
        options: SearchOptionsResponse?,
        isNovelTab: Bool,
        onChange: @escaping (SearchFilter) -> Void,
        onReloadOptions: @escaping () -> Void,
        onApply: @escaping (SearchFilter) async -> Void
    ) {
        _draft = State(initialValue: filter)
        self.options = options
        self.isNovelTab = isNovelTab
        self.onChange = onChange
        self.onReloadOptions = onReloadOptions
        self.onApply = onApply
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 0) {
                        row(.target, l10n.t(.filterMatch), targetLabel(draft.target), .first)
                        divider
                        row(
                            .sort, l10n.t(.searchSortLabel), sortLabel(draft.sort),
                            isNovelTab ? .last : .middle
                        )
                        if !isNovelTab {
                            divider
                            row(
                                .contentType, l10n.t(.filterWorkType),
                                contentTypeLabel(draft.contentType), .last
                            )
                        }
                    }

                    VStack(spacing: 0) {
                        row(.duration, l10n.t(.filterDatePosted), durationSummary, .first)
                        divider
                        row(.bookmarks, l10n.t(.filterBookmarks), bookmarkSummary, .middle)
                        divider
                        row(.keywordUsers, l10n.t(.filterPopularityTag), keywordUsersSummary, .middle)
                        if isNovelTab {
                            divider
                            row(.genre, l10n.t(.filterGenre), genreSummary, .middle)
                            divider
                            row(.language, l10n.t(.filterWorkLanguage), languageSummary, .middle)
                        } else {
                            divider
                            row(.ratio, l10n.t(.filterAspectRatio), ratioSummary, .middle)
                            divider
                            row(.resolution, l10n.t(.filterResolution), resolutionSummary, .last)
                        }
                        if isNovelTab {
                            divider
                            row(.bodyLength, l10n.t(.filterLength), bodyLengthSummary, .last)
                        }
                    }

                    row(.other, l10n.t(.filterOther), otherSummary, .single)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }

            Button {
                let value = draft
                Task { await onApply(value) }
                dismiss()
            } label: {
                Text(l10n.t(.filterSearch))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.brand, in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(Theme.v3Bg.ignoresSafeArea())
        .presentationDetents([.fraction(0.92)])
        .presentationDragIndicator(.hidden)
        .onChange(of: draft) { _, value in onChange(value) }
        .sheet(item: $editor, onDismiss: openPendingEditor) { value in
            editorView(value)
                .presentationDetents([.fraction(0.85)])
                .presentationDragIndicator(.hidden)
        }
    }

    private var topBar: some View {
        ZStack {
            Text(l10n.t(.filterSearchConditions))
                .font(.headline)
            HStack {
                Button(l10n.t(.actionCancel)) { dismiss() }
                    .foregroundStyle(Theme.v3TextAccent)
                Spacer()
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 20)
    }

    private func row(
        _ target: Editor,
        _ title: String,
        _ value: String,
        _ position: V3SegmentPosition
    ) -> some View {
        Button {
            if target == .genre, genreOptions.isEmpty {
                onReloadOptions(); return
            }
            if target == .language, languageOptions.isEmpty {
                onReloadOptions(); return
            }
            if target == .bookmarks { bookmarkPresetsShown = bookmarkPresets }
            editor = target
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.v3Text1)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.v3TextAccent)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                Text("›")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.v3Text3)
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 18)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .v3Segment(position)
    }

    private var divider: some View {
        Color.clear.frame(height: 2)
    }

    // MARK: Editors

    @ViewBuilder
    private func editorView(_ editor: Editor) -> some View {
        switch editor {
        case .target:
            ChoiceSheet(
                title: l10n.t(.filterMatch), selected: draft.target,
                choices: targetChoices.map { ($0, targetLabel($0)) }
            ) { draft.target = $0 }
        case .sort:
            ChoiceSheet(
                title: l10n.t(.searchSortLabel), selected: draft.sort,
                choices: SortType.choices(isNovel: isNovelTab).map { ($0, sortLabel($0)) }
            ) {
                draft.sort = $0
                SearchDefaults.save(sort: $0)
                AppSettingsStore.shared.searchSortIndex = SearchDefaults.index(of: $0)
            }
        case .contentType:
            ChoiceSheet(
                title: l10n.t(.filterWorkType), selected: draft.contentType,
                choices: IllustContentType.allCases.map { ($0, contentTypeLabel($0)) }
            ) { draft.contentType = $0 }
        case .duration:
            DurationChoiceSheet(filter: draft) { choice in
                switch choice {
                case .any:
                    draft.duration = nil; draft.startDate = nil; draft.endDate = nil
                case .custom:
                    pendingEditor = .dateRange
                default:
                    draft.duration = choice.bucket; draft.startDate = nil; draft.endDate = nil
                }
            }
        case .dateRange:
            DateRangeSheet(start: draft.startDate, end: draft.endDate) { start, end in
                draft.duration = nil; draft.startDate = start; draft.endDate = end
            }
        case .bookmarks:
            BookmarkChoiceSheet(
                selected: draft.bookmarkRange,
                presets: bookmarkPresetsShown ?? bookmarkPresets
            ) { choice in
                if choice == .custom { pendingEditor = .bookmarkRange }
                else { draft.bookmarkRange = choice.range }
            }
        case .bookmarkRange:
            NumberRangeSheet(
                title: l10n.t(.filterBookmarkCustom), unit: "",
                minimum: draft.bookmarkRange?.min, maximum: draft.bookmarkRange?.max
            ) { min, max in
                draft.bookmarkRange = min == nil && max == nil ? nil : BookmarkRange(min: min, max: max)
            }
        case .keywordUsers:
            ChoiceSheet(
                title: l10n.t(.filterPopularityTag), selected: draft.keywordUsers,
                choices: KeywordUsersOptions.values.map {
                    ($0, $0 == 0 ? l10n.t(.filterDisabled) : "\($0)users入り")
                }
            ) { draft.keywordUsers = $0 }
        case .genre:
            ChoiceSheet(
                title: l10n.t(.filterGenre), selected: draft.genre,
                choices: [(Int?.none, l10n.t(.filterGenreAll))] + genreOptions.map { (Int?.some($0.id), $0.label) }
            ) { draft.genre = $0 }
        case .language:
            ChoiceSheet(
                title: l10n.t(.filterWorkLanguage), selected: draft.language,
                choices: [(String?.none, l10n.t(.filterLanguageAll))] + languageOptions.map { (String?.some($0.code), $0.name) }
            ) { draft.language = $0 }
        case .ratio:
            ChoiceSheet(
                title: l10n.t(.filterAspectRatio), selected: draft.ratio,
                choices: [(RatioPattern?.none, l10n.t(.filterRatioAll))] +
                    RatioPattern.allCases.map { (RatioPattern?.some($0), ratioLabel($0)) }
            ) { draft.ratio = $0 }
        case .resolution:
            ChoiceSheet(
                title: l10n.t(.filterResolution), selected: draft.resolution,
                choices: [(ResolutionBucket?.none, l10n.t(.filterResolutionAll))] +
                    ResolutionBucket.allCases.map { (ResolutionBucket?.some($0), resolutionLabel($0)) }
            ) { draft.resolution = $0 }
        case .bodyLength:
            BodyLengthChoiceSheet(
                selected: draft.bodyLength,
                footerHint: options?.novel?.wordCountSupportedLanguages
            ) { choice in
                switch choice {
                case .none: draft.bodyLength = nil
                case .preset(let length): draft.bodyLength = length
                case .custom(let unit): pendingEditor = .bodyRange(unit)
                }
            }
        case .bodyRange(let unit):
            NumberRangeSheet(
                title: bodyCustomTitle(unit), unit: bodyInputUnitLabel(unit),
                minimum: draft.bodyLength?.unit == unit ? draft.bodyLength?.min : nil,
                maximum: draft.bodyLength?.unit == unit ? draft.bodyLength?.max : nil
            ) { min, max in
                draft.bodyLength = min == nil && max == nil ? nil : BodyLength(unit: unit, min: min, max: max)
            }
        case .other:
            OtherFilterSheet(
                filter: draft, isNovel: isNovelTab, tools: toolOptions,
                onReloadOptions: onReloadOptions
            ) { value in
                draft.ai = value.ai
                draft.r18 = value.r18
                draft.tool = isNovelTab ? nil : value.tool
                draft.originalOnly = isNovelTab && value.originalOnly
                draft.replaceableOnly = isNovelTab && value.replaceableOnly
                draft.groupBySeries = isNovelTab && value.groupBySeries
                if value.ai != .onlyAI {
                    AppSettingsStore.shared.deleteAIIllust = value.ai == .excludeAI
                }
            }
        }
    }

    private var targetChoices: [SearchTarget] {
        isNovelTab ? SearchTarget.forNovel : SearchTarget.forIllust
    }
    private var bookmarkPresets: [BookmarkRange] {
        let dynamic = (isNovelTab ? options?.novel : options?.illust)?
            .bookmarkRanges?.compactMap(\.range) ?? []
        return dynamic.isEmpty ? BookmarkRange.defaultPresets : dynamic
    }
    private var toolOptions: [String] { options?.illust?.tool?.options ?? [] }
    private var genreOptions: [SearchOptionsResponse.GenreOption] { options?.novel?.genre?.options ?? [] }
    private var languageOptions: [SearchOptionsResponse.LangOption] {
        (isNovelTab ? options?.novel?.lang : options?.illust?.lang)?.options ?? []
    }

    // MARK: Summaries

    private func sortLabel(_ value: String) -> String {
        switch value {
        case SortType.popularPreview: return l10n.t(.sortPopularPreview)
        case SortType.dateDesc: return l10n.t(.searchSortDateDesc)
        case SortType.dateAsc: return l10n.t(.searchSortDateAsc)
        case SortType.popularDesc: return l10n.t(.searchSortPopular)
        case SortType.popularMaleDesc: return l10n.t(.sortPopularMale)
        case SortType.popularFemaleDesc: return l10n.t(.sortPopularFemale)
        default: return l10n.t(.sortPopularPreview)
        }
    }
    private func targetLabel(_ value: SearchTarget) -> String {
        switch value {
        case .partialTags: return l10n.t(.searchTargetPartial)
        case .exactTags: return l10n.t(.searchTargetExact)
        case .titleCaption: return l10n.t(.searchTargetTitleCaption)
        case .novelText: return l10n.t(.targetText)
        case .novelKeyword: return l10n.t(.targetKeyword)
        }
    }
    private var durationSummary: String {
        if let duration = draft.duration { return DurationChoice(bucket: duration).label(l10n) }
        if draft.startDate != nil || draft.endDate != nil {
            return "\(draft.startDate.map(SearchFilter.ymd) ?? "—") → \(draft.endDate.map(SearchFilter.ymd) ?? "—")"
        }
        return l10n.t(.filterDurationAll)
    }
    private var bookmarkSummary: String { rangeLabel(draft.bookmarkRange) }
    private var keywordUsersSummary: String {
        draft.keywordUsers == 0 ? l10n.t(.filterDisabled) : "\(draft.keywordUsers)users入り"
    }
    private var genreSummary: String {
        genreOptions.first { $0.id == draft.genre }?.label ?? l10n.t(.filterGenreAll)
    }
    private var languageSummary: String {
        languageOptions.first { $0.code == draft.language }?.name ?? l10n.t(.filterLanguageAll)
    }
    private var ratioSummary: String { draft.ratio.map(ratioLabel) ?? l10n.t(.filterRatioAll) }
    private var resolutionSummary: String { draft.resolution.map(resolutionLabel) ?? l10n.t(.filterResolutionAll) }
    private var bodyLengthSummary: String {
        guard let value = draft.bodyLength else { return l10n.t(.filterBodyAll) }
        if let index = value.unit.buckets.firstIndex(where: {
            $0.min == value.min && $0.max == value.max
        }) {
            return bodyPresetLabel(value.unit, index)
        }
        let range = bodyRangeText(value.min, value.max)
        switch value.unit {
        case .characters: return l10n.t(.bodyCustomCharsFmt, range)
        case .words: return l10n.t(.bodyCustomWordsFmt, range)
        case .readingTime: return l10n.t(.bodyCustomTimeFmt, range)
        }
    }
    private var otherSummary: String {
        var values: [String] = []
        if draft.ai == .excludeAI { values.append(l10n.t(.filterSummaryNoAI)) }
        if draft.ai == .onlyAI { values.append(l10n.t(.filterSummaryOnlyAI)) }
        if draft.r18 == .safeOnly { values.append(l10n.t(.filterSafeOnly)) }
        if draft.r18 == .r18Only { values.append(l10n.t(.filterR18Only)) }
        if !isNovelTab, let tool = draft.tool { values.append(tool) }
        if isNovelTab, draft.originalOnly { values.append(l10n.t(.filterOriginalOnly)) }
        if isNovelTab, draft.replaceableOnly { values.append(l10n.t(.filterReplaceableOnly)) }
        if isNovelTab, draft.groupBySeries { values.append(l10n.t(.filterGroupBySeries)) }
        return values.isEmpty ? l10n.t(.filterNone) : values.joined(separator: " · ")
    }

    private func rangeLabel(_ range: BookmarkRange?) -> String {
        guard let range else { return l10n.t(.filterBookmarkAll) }
        return rangeText(range.min, range.max)
    }
    private func rangeText(_ min: Int?, _ max: Int?) -> String {
        switch (min, max) {
        case let (a?, b?): return "\(a) ~ \(b)"
        case let (a?, nil): return "\(a)+"
        case let (nil, b?): return "~ \(b)"
        default: return l10n.t(.filterAny)
        }
    }
    private func bodyRangeText(_ min: Int?, _ max: Int?) -> String {
        switch (min, max) {
        case let (a?, b?): return "\(a)–\(b)"
        case let (a?, nil): return "≥\(a)"
        case let (nil, b?): return "≤\(b)"
        default: return "—"
        }
    }
    private func ratioLabel(_ value: RatioPattern) -> String {
        switch value {
        case .landscape: return l10n.t(.ratioLandscape)
        case .portrait: return l10n.t(.ratioPortrait)
        case .square: return l10n.t(.ratioSquare)
        }
    }
    private func resolutionLabel(_ value: ResolutionBucket) -> String {
        switch value {
        case .above3000: return l10n.t(.filterResolutionAbove)
        case .between1000And2999: return l10n.t(.filterResolutionMiddle)
        case .below1000: return l10n.t(.filterResolutionBelow)
        }
    }
    private func contentTypeLabel(_ value: IllustContentType) -> String {
        switch value {
        case .all: return l10n.t(.filterContentAll)
        case .illustAndUgoira: return l10n.t(.filterContentIllustUgoira)
        case .illust: return l10n.t(.typeIllust)
        case .ugoira: return l10n.t(.typeUgoira)
        case .manga: return l10n.t(.profileManga)
        }
    }
    private func bodyUnitLabel(_ unit: BodyLengthUnit) -> String {
        switch unit {
        case .characters: return l10n.t(.bodyUnitChars)
        case .words: return l10n.t(.bodyUnitWords)
        case .readingTime: return l10n.t(.bodyUnitReadingTime)
        }
    }
    private func bodyInputUnitLabel(_ unit: BodyLengthUnit) -> String {
        switch unit {
        case .characters: return l10n.t(.bodyUnitCharShort)
        case .words: return l10n.t(.bodyUnitWordShort)
        case .readingTime: return l10n.t(.bodyUnitMinute)
        }
    }
    private func bodyPresetLabel(_ unit: BodyLengthUnit, _ index: Int) -> String {
        let keys: [LocalizedKey]
        switch unit {
        case .characters: keys = [.bodyCharsMicro, .bodyCharsShort, .bodyCharsMedium, .bodyCharsLong]
        case .words: keys = [.bodyWordsBelow, .bodyWordsFrom5K, .bodyWordsFrom20K, .bodyWordsAbove80K]
        case .readingTime: keys = [.bodyTimeUnder10, .bodyTime10To59, .bodyTime60To179, .bodyTimeAbove180]
        }
        return keys.indices.contains(index) ? l10n.t(keys[index]) : l10n.t(.filterAny)
    }
    private func bodyCustomTitle(_ unit: BodyLengthUnit) -> String {
        "\(l10n.t(.filterCustom))\(bodyUnitLabel(unit))"
    }

    private func openPendingEditor() {
        guard let next = pendingEditor else { return }
        pendingEditor = nil
        // Presenting a second sheet in the same dismissal transaction is
        // ignored by SwiftUI. One yield matches FragmentResult's two-stage flow.
        Task { @MainActor in
            await Task.yield()
            editor = next
        }
    }

    private enum Editor: Identifiable, Hashable {
        case target, sort, contentType, duration, dateRange, bookmarks, bookmarkRange
        case keywordUsers, genre, language, ratio, resolution, bodyLength, bodyRange(BodyLengthUnit), other
        var id: String { String(describing: self) }
    }

}

private enum V3SegmentPosition { case first, middle, last, single }

private func v3SegmentPosition(index: Int, count: Int) -> V3SegmentPosition {
    if count <= 1 { return .single }
    if index == 0 { return .first }
    if index == count - 1 { return .last }
    return .middle
}

private func v3SegmentShape(_ position: V3SegmentPosition) -> UnevenRoundedRectangle {
    let top: CGFloat = position == .first || position == .single ? 20 : 5
    let bottom: CGFloat = position == .last || position == .single ? 20 : 5
    return UnevenRoundedRectangle(cornerRadii: .init(
        topLeading: top, bottomLeading: bottom,
        bottomTrailing: bottom, topTrailing: top
    ))
}

private extension View {
    func v3Segment(_ position: V3SegmentPosition) -> some View {
        let shape = v3SegmentShape(position)
        return background(Theme.v3CardFill, in: shape)
            .overlay(shape.strokeBorder(Theme.v3CardHairline, lineWidth: 0.5))
    }
}

/// Shared 56pt V3 sheet bar: accent Cancel, centered bold title and optional
/// accent confirmation action. It mirrors every Android child sheet header.
private struct V3SheetTopBar: View {
    let title: String
    var confirmTitle: String? = nil
    var onConfirm: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.v3Text1)
            HStack {
                Button(l10n.t(.actionCancel)) { dismiss() }
                    .foregroundStyle(Theme.v3TextAccent)
                Spacer()
                if let confirmTitle, let onConfirm {
                    Button(confirmTitle, action: onConfirm)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.v3TextAccent)
                }
            }
            .font(.system(size: 16))
        }
        .frame(height: 56)
        .padding(.horizontal, 20)
    }
}

private struct ChoiceSheet<Value: Hashable>: View {
    let title: String
    let selected: Value
    let choices: [(Value, String)]
    let onSelect: (Value) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            V3SheetTopBar(title: title)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, item in
                        Button {
                            onSelect(item.0); dismiss()
                        } label: {
                            HStack {
                                Text(item.1)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.v3Text1)
                                Spacer()
                                Text("✓")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.v3TextAccent)
                                    .opacity(item.0 == selected ? 1 : 0)
                            }
                            .frame(minHeight: 52)
                            .padding(.horizontal, 18)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .v3Segment(v3SegmentPosition(index: index, count: choices.count))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.v3Bg.ignoresSafeArea())
    }
}

private enum DurationChoice: Hashable, CaseIterable {
    case any, day, week, month, halfYear, year, custom
    init(bucket: DurationBucket) {
        switch bucket {
        case .last24Hours: self = .day
        case .lastWeek: self = .week
        case .lastMonth: self = .month
        case .lastHalfYear: self = .halfYear
        case .lastYear: self = .year
        }
    }
    var bucket: DurationBucket? {
        switch self {
        case .day: return .last24Hours
        case .week: return .lastWeek
        case .month: return .lastMonth
        case .halfYear: return .lastHalfYear
        case .year: return .lastYear
        default: return nil
        }
    }
    @MainActor func label(_ l10n: OnboardingStore) -> String {
        switch self {
        case .any: return l10n.t(.filterDurationAll)
        case .day: return l10n.t(.searchDurationDay)
        case .week: return l10n.t(.searchDurationWeek)
        case .month: return l10n.t(.searchDurationMonth)
        case .halfYear: return l10n.t(.durationHalfYear)
        case .year: return l10n.t(.durationYear)
        case .custom: return l10n.t(.filterCustomRange)
        }
    }
}

private struct DurationChoiceSheet: View {
    let filter: SearchFilter
    let onSelect: (DurationChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n
    private var selected: DurationChoice {
        if let value = filter.duration { return DurationChoice(bucket: value) }
        if filter.startDate != nil || filter.endDate != nil { return .custom }
        return .any
    }
    var body: some View {
        ChoiceSheet(
            title: l10n.t(.filterDatePosted), selected: selected,
            choices: DurationChoice.allCases.map { ($0, $0.label(l10n)) }
        ) { value in onSelect(value); dismiss() }
    }
}

private enum BookmarkChoice: Hashable {
    case unlimited, preset(BookmarkRange), custom
    var range: BookmarkRange? { if case .preset(let value) = self { value } else { nil } }
}

private struct BookmarkChoiceSheet: View {
    let selected: BookmarkRange?
    let presets: [BookmarkRange]
    let onSelect: (BookmarkChoice) -> Void
    @Environment(OnboardingStore.self) private var l10n
    var body: some View {
        ChoiceSheet(
            title: l10n.t(.filterBookmarks),
            selected: currentChoice,
            choices: [(.unlimited, l10n.t(.filterBookmarkAll))]
                + presets.map { (.preset($0), label($0)) }
                + [(.custom, l10n.t(.filterBookmarkCustom))],
            onSelect: onSelect
        )
    }
    private var currentChoice: BookmarkChoice {
        guard let selected else { return .unlimited }
        return presets.contains(selected) ? .preset(selected) : .custom
    }
    private func label(_ value: BookmarkRange) -> String {
        switch (value.min, value.max) {
        case let (a?, b?): return "\(a) ~ \(b)"
        case let (a?, nil): return "\(a)+"
        case let (nil, b?): return "~ \(b)"
        default: return l10n.t(.filterAny)
        }
    }
}

private struct NumberRangeSheet: View {
    let title: String
    let unit: String
    let onApply: (Int?, Int?) -> Void
    @State private var minimum: String
    @State private var maximum: String
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    init(title: String, unit: String, minimum: Int?, maximum: Int?, onApply: @escaping (Int?, Int?) -> Void) {
        self.title = title; self.unit = unit; self.onApply = onApply
        _minimum = State(initialValue: minimum.map(String.init) ?? "")
        _maximum = State(initialValue: maximum.map(String.init) ?? "")
    }
    var body: some View {
        VStack(spacing: 0) {
            V3SheetTopBar(title: title, confirmTitle: l10n.t(.filterRangeConfirm)) { commit() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 2) {
                        numberRow(label: l10n.t(.filterMinimum), text: $minimum)
                            .v3Segment(.first)
                        numberRow(label: l10n.t(.filterMaximum), text: $maximum)
                            .v3Segment(.last)
                    }
                    Text(l10n.t(.filterRangeHint))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3Text3)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.v3Bg.ignoresSafeArea())
    }

    private func numberRow(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.v3Text1)
            TextField(l10n.t(.filterRangeUnlimited), text: text)
                .font(.system(size: 15))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            if !unit.isEmpty {
                Text(unit).font(.system(size: 14)).foregroundStyle(Theme.v3Text3)
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 18)
    }

    private func commit() {
        let a = valid(minimum), b = valid(maximum)
        if let a, let b, a > b { onApply(b, a) }
        else { onApply(a, b) }
        dismiss()
    }
    private func valid(_ text: String) -> Int? { Int(text).flatMap { $0 >= 0 ? $0 : nil } }
}

private struct DateRangeSheet: View {
    @State private var start: Date
    @State private var end: Date
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    let onApply: (Date?, Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n
    init(start: Date?, end: Date?, onApply: @escaping (Date?, Date?) -> Void) {
        let a = start ?? end ?? Date(), b = end ?? start ?? Date()
        _start = State(initialValue: min(a, b)); _end = State(initialValue: max(a, b))
        _hasStart = State(initialValue: start != nil)
        _hasEnd = State(initialValue: end != nil)
        self.onApply = onApply
    }
    var body: some View {
        VStack(spacing: 0) {
            V3SheetTopBar(title: l10n.t(.filterCustomRange), confirmTitle: l10n.t(.filterConfirm)) {
                onApply(hasStart ? start : nil, hasEnd ? end : nil)
                dismiss()
            }
            ScrollView {
                VStack(spacing: 2) {
                    dateRow(
                        title: l10n.t(.filterDateStart), enabled: $hasStart,
                        value: $start, range: earliest...(hasEnd ? end : Date())
                    )
                    .v3Segment(.first)
                    dateRow(
                        title: l10n.t(.filterDateEnd), enabled: $hasEnd,
                        value: $end, range: (hasStart ? start : earliest)...Date()
                    )
                    .v3Segment(hasStart || hasEnd ? .middle : .last)
                    if hasStart || hasEnd {
                        Button {
                            hasStart = false; hasEnd = false
                        } label: {
                            Text(l10n.t(.filterClearDates))
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.v3TextAccent)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .v3Segment(.last)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.v3Bg.ignoresSafeArea())
    }

    private func dateRow(
        title: String,
        enabled: Binding<Bool>,
        value: Binding<Date>,
        range: ClosedRange<Date>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.v3Text1)
            Spacer()
            if enabled.wrappedValue {
                DatePicker("", selection: value, in: range, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            } else {
                Button(l10n.t(.filterDateUnset)) { enabled.wrappedValue = true }
                    .foregroundStyle(Theme.v3TextAccent)
            }
            Text("›").font(.system(size: 20)).foregroundStyle(Theme.v3Text3)
        }
        .frame(minHeight: 56)
        .padding(.horizontal, 18)
    }
    private var earliest: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2007, month: 9, day: 10)) ?? .distantPast
    }
}

private enum BodyLengthChoice: Hashable {
    case none, preset(BodyLength), custom(BodyLengthUnit)
}

private struct BodyLengthChoiceSheet: View {
    let selected: BodyLength?
    let footerHint: String?
    let onSelect: (BodyLengthChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n
    var body: some View {
        VStack(spacing: 0) {
            V3SheetTopBar(title: l10n.t(.filterLength))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 2) {
                        button(.none, l10n.t(.filterBodyAll))
                            .v3Segment(.single)
                        ForEach(BodyLengthUnit.allCases, id: \.self) { unit in
                            Text(unitLabel(unit))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.v3Text3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                            ForEach(Array(unit.buckets.enumerated()), id: \.offset) { index, range in
                                button(
                                    .preset(.init(unit: unit, min: range.min, max: range.max)),
                                    presetLabel(unit, index)
                                )
                                .v3Segment(v3SegmentPosition(
                                    index: index, count: unit.buckets.count + 1
                                ))
                            }
                            button(.custom(unit), "\(l10n.t(.filterCustom))\(unitLabel(unit)) (P)")
                                .v3Segment(.last)
                        }
                    }
                    if let footerHint, !footerHint.isEmpty {
                        Text(footerHint)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.v3Text3)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.v3Bg.ignoresSafeArea())
    }
    private func button(_ value: BodyLengthChoice, _ title: String) -> some View {
        Button { onSelect(value); dismiss() } label: {
            HStack {
                Text(title).foregroundStyle(.primary); Spacer()
                Text("✓").font(.system(size: 20)).foregroundStyle(Theme.v3TextAccent)
                    .opacity(isSelected(value) ? 1 : 0)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 18)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
    private func isSelected(_ value: BodyLengthChoice) -> Bool {
        switch value {
        case .none: return selected == nil
        case .preset(let body): return body == selected
        case .custom(let unit):
            guard let selected, selected.unit == unit else { return false }
            return !unit.buckets.contains { $0.min == selected.min && $0.max == selected.max }
        }
    }
    private func unitLabel(_ unit: BodyLengthUnit) -> String {
        switch unit {
        case .characters: return l10n.t(.bodyUnitChars)
        case .words: return l10n.t(.bodyUnitWords)
        case .readingTime: return l10n.t(.bodyUnitReadingTime)
        }
    }
    private func rangeLabel(_ range: (min: Int?, max: Int?)) -> String {
        switch (range.min, range.max) {
        case let (nil, b?): return "≤ \(b)"
        case let (a?, nil): return "≥ \(a)"
        case let (a?, b?): return "\(a) – \(b)"
        default: return l10n.t(.filterAny)
        }
    }
    private func presetLabel(_ unit: BodyLengthUnit, _ index: Int) -> String {
        let keys: [LocalizedKey]
        switch unit {
        case .characters: keys = [.bodyCharsMicro, .bodyCharsShort, .bodyCharsMedium, .bodyCharsLong]
        case .words: keys = [.bodyWordsBelow, .bodyWordsFrom5K, .bodyWordsFrom20K, .bodyWordsAbove80K]
        case .readingTime: keys = [.bodyTimeUnder10, .bodyTime10To59, .bodyTime60To179, .bodyTimeAbove180]
        }
        return keys.indices.contains(index) ? l10n.t(keys[index]) : rangeLabel(unit.buckets[index])
    }
}

private struct OtherFilterSheet: View {
    struct Value {
        var ai: AIMode; var r18: R18Mode; var tool: String?
        var originalOnly: Bool; var replaceableOnly: Bool; var groupBySeries: Bool
    }
    @State private var value: Value
    @State private var showToolPicker = false
    @State private var toolLoadingHintToken: UUID?
    let isNovel: Bool
    let tools: [String]
    let onReloadOptions: () -> Void
    let onApply: (Value) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n
    init(
        filter: SearchFilter,
        isNovel: Bool,
        tools: [String],
        onReloadOptions: @escaping () -> Void,
        onApply: @escaping (Value) -> Void
    ) {
        _value = State(initialValue: Value(
            ai: filter.ai, r18: filter.r18, tool: filter.tool,
            originalOnly: filter.originalOnly, replaceableOnly: filter.replaceableOnly,
            groupBySeries: filter.groupBySeries
        ))
        self.isNovel = isNovel
        self.tools = tools
        self.onReloadOptions = onReloadOptions
        self.onApply = onApply
    }
    var body: some View {
        VStack(spacing: 0) {
            V3SheetTopBar(title: l10n.t(.filterOther), confirmTitle: l10n.t(.filterConfirm)) {
                onApply(value); dismiss()
            }
            ScrollView {
                VStack(spacing: 20) {
                    radioCard(title: l10n.t(.filterAIWorks), values: [
                        (AIMode.all, l10n.t(.filterAll)),
                        (.excludeAI, l10n.t(.filterExcludeAI)),
                        (.onlyAI, l10n.t(.filterOnlyAI)),
                    ], selection: $value.ai)
                    if !isNovel {
                        Button {
                            if tools.isEmpty {
                                onReloadOptions()
                                showToolLoadingHint()
                            } else {
                                showToolPicker = true
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text(l10n.t(.filterTool))
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.v3Text1)
                                Spacer()
                                Text(value.tool ?? l10n.t(.filterToolAll))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.v3TextAccent)
                                Text("›")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.v3Text3)
                            }
                            .frame(minHeight: 56)
                            .padding(.horizontal, 18)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .v3Segment(.single)
                    }
                    if isNovel {
                        VStack(spacing: 2) {
                            switchRow(l10n.t(.filterOriginalOnly), value: $value.originalOnly)
                                .v3Segment(.first)
                            switchRow(l10n.t(.filterReplaceableOnly), value: $value.replaceableOnly)
                                .v3Segment(.middle)
                            switchRow(
                                l10n.t(.filterGroupBySeries),
                                subtitle: l10n.t(.filterGroupBySeriesHint),
                                value: $value.groupBySeries
                            )
                            .v3Segment(.last)
                        }
                    }
                    radioCard(title: l10n.t(.filterAgeRating), values: [
                        (R18Mode.all, l10n.t(.filterAll)),
                        (.safeOnly, l10n.t(.filterSafeOnly)),
                        (.r18Only, l10n.t(.filterR18Only)),
                    ], selection: $value.r18)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.v3Bg.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if toolLoadingHintToken != nil {
                Text(l10n.t(.filterToolLoading))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.78), in: .capsule)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showToolPicker) {
            ChoiceSheet(
                title: l10n.t(.filterTool), selected: value.tool,
                choices: [(String?.none, l10n.t(.filterToolAll))]
                    + tools.map { (String?.some($0), $0) }
            ) { value.tool = $0 }
            .presentationDetents([.fraction(0.85)])
            .presentationDragIndicator(.hidden)
        }
    }

    private func showToolLoadingHint() {
        let token = UUID()
        withAnimation { toolLoadingHintToken = token }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard toolLoadingHintToken == token else { return }
            withAnimation { toolLoadingHintToken = nil }
        }
    }

    private func switchRow(_ title: String, subtitle: String? = nil, value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15)).foregroundStyle(Theme.v3Text1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.v3Text3)
                }
            }
            Spacer()
            Toggle("", isOn: value).labelsHidden().tint(Theme.brand)
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 18)
    }
    private func radioCard<T: Hashable>(title: String, values: [(T, String)], selection: Binding<T>) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Theme.v3Text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            ForEach(Array(values.enumerated()), id: \.offset) { index, item in
                Button { selection.wrappedValue = item.0 } label: {
                    HStack {
                        Text(item.1).foregroundStyle(.primary); Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.v3TextAccent)
                            .opacity(selection.wrappedValue == item.0 ? 1 : 0)
                    }.padding(.horizontal, 18).frame(minHeight: 52)
                }
                .buttonStyle(.plain)
                .v3Segment(v3SegmentPosition(index: index, count: values.count))
            }
        }
    }
}

/// The Android setting and the filter picker write one shared field. Store the
/// wire value (not a fragile UI index); old integer values are migrated by read.
enum SearchDefaults {
    private static let key = "search_default_sort_wire_v2"
    static let values = [
        SortType.popularPreview,
        SortType.dateDesc,
        SortType.dateAsc,
        SortType.popularDesc,
        SortType.popularMaleDesc,
        SortType.popularFemaleDesc,
    ]

    static func save(sort: String) { UserDefaults.standard.set(sort, forKey: key) }
    static func index(of sort: String) -> Int { values.firstIndex(of: sort) ?? 3 }

    static var sort: String {
        if let value = UserDefaults.standard.string(forKey: key), values.contains(value) {
            return value
        }
        // Migrate the iOS port's old integer setting once. Its four rows were
        // newest / oldest / official popularity / built-in popularity.
        if UserDefaults.standard.object(forKey: "st_searchDefaultSortType") != nil {
            let legacy = UserDefaults.standard.integer(forKey: "st_searchDefaultSortType")
            let legacyValues = [
                SortType.dateDesc, SortType.dateAsc,
                SortType.popularDesc, SortType.popularDesc,
            ]
            return legacyValues.indices.contains(legacy)
                ? legacyValues[legacy]
                : SortType.popularDesc
        }
        return SortType.popularDesc
    }
}
