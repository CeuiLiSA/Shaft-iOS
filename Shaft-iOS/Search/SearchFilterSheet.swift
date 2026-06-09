import SwiftUI

/// The V3 search filter sheet — a native iOS adaptation of Pixiv-Shaft's
/// `SearchFilterV3BottomSheet`. Edits a draft `SearchFilter` and hands it back
/// on "Apply"; one filter drives both the illust and novel tabs, with
/// illust-only / novel-only dimensions grouped into their own sections.
struct SearchFilterSheet: View {
    @State private var draft: SearchFilter
    let options: SearchOptionsResponse?
    let isNovelTab: Bool
    let isPremium: Bool
    let onApply: (SearchFilter) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    // Local mirrors for the compound date / body-length dimensions.
    @State private var dateChoice: DateChoice
    @State private var bodyUnit: BodyLengthUnit
    @State private var bodyBucket: Int   // -1 = any, else index into unit.buckets

    init(
        filter: SearchFilter,
        options: SearchOptionsResponse?,
        isNovelTab: Bool,
        isPremium: Bool,
        onApply: @escaping (SearchFilter) async -> Void
    ) {
        _draft = State(initialValue: filter)
        self.options = options
        self.isNovelTab = isNovelTab
        self.isPremium = isPremium
        self.onApply = onApply
        _dateChoice = State(initialValue: DateChoice(filter: filter))
        let unit = filter.bodyLength?.unit ?? .characters
        _bodyUnit = State(initialValue: unit)
        _bodyBucket = State(initialValue: Self.bucketIndex(of: filter.bodyLength, unit: unit))
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                illustSection
                novelSection
            }
            .navigationTitle(l10n.t(.filterTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(l10n.t(.filterReset)) {
                        resetDraft()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t(.filterApply)) {
                        let f = draft
                        Task { await onApply(f) }
                        dismiss()
                    }.bold()
                }
            }
        }
    }

    // MARK: General (applies to both tabs)

    private var generalSection: some View {
        Section {
            Picker(l10n.t(.searchSortLabel), selection: $draft.sort) {
                ForEach(sortChoices, id: \.self) { Text(sortLabel($0)).tag($0) }
            }

            Picker(l10n.t(.filterMatch), selection: $draft.target) {
                ForEach(targetChoices, id: \.self) { Text(targetLabel($0)).tag($0) }
            }

            Picker(l10n.t(.filterBookmarks), selection: $draft.bookmarkMin) {
                ForEach(BookmarkOptions.values, id: \.self) {
                    Text($0 == 0 ? l10n.t(.filterAny) : "\($0)+").tag($0)
                }
            }

            Picker(l10n.t(.filterPopularityTag), selection: $draft.keywordUsers) {
                ForEach(KeywordUsersOptions.values, id: \.self) {
                    Text($0 == 0 ? l10n.t(.filterAny) : "\($0)users入り").tag($0)
                }
            }

            if !langOptions.isEmpty {
                Picker(l10n.t(.settingsLanguage), selection: $draft.language) {
                    Text(l10n.t(.filterAny)).tag(String?.none)
                    ForEach(langOptions) { Text($0.name).tag(String?.some($0.code)) }
                }
            }

            Picker(l10n.t(.filterDatePosted), selection: $dateChoice) {
                ForEach(DateChoice.allCases, id: \.self) { Text(dateLabel($0)).tag($0) }
            }
            .onChange(of: dateChoice) { _, choice in applyDateChoice(choice) }

            if dateChoice == .custom {
                DatePicker(
                    l10n.t(.filterCustomRange),
                    selection: Binding(
                        get: { draft.startDate ?? Date() },
                        set: { draft.startDate = $0 }
                    ),
                    in: ...(draft.endDate ?? Date()),
                    displayedComponents: .date
                )
                DatePicker(
                    "—",
                    selection: Binding(
                        get: { draft.endDate ?? Date() },
                        set: { draft.endDate = $0 }
                    ),
                    in: (draft.startDate ?? .distantPast)...Date(),
                    displayedComponents: .date
                )
            }

            Picker(l10n.t(.filterAIWorks), selection: $draft.ai) {
                Text(l10n.t(.filterAny)).tag(AIMode.all)
                Text(l10n.t(.filterExcludeAI)).tag(AIMode.excludeAI)
                Text(l10n.t(.filterOnlyAI)).tag(AIMode.onlyAI)
            }

            Picker(l10n.t(.filterAgeRating), selection: $draft.r18) {
                Text(l10n.t(.filterAny)).tag(R18Mode.all)
                Text(l10n.t(.filterSafeOnly)).tag(R18Mode.safeOnly)
                Text(l10n.t(.filterR18Only)).tag(R18Mode.r18Only)
            }
        }
    }

    // MARK: Illustration-only

    private var illustSection: some View {
        Section(l10n.t(.searchTabIllust)) {
            Picker(l10n.t(.filterWorkType), selection: $draft.contentType) {
                ForEach(IllustContentType.allCases, id: \.self) { Text(contentTypeLabel($0)).tag($0) }
            }

            Picker(l10n.t(.filterAspectRatio), selection: $draft.ratio) {
                Text(l10n.t(.filterAny)).tag(RatioPattern?.none)
                ForEach(RatioPattern.allCases, id: \.self) { Text(ratioLabel($0)).tag(RatioPattern?.some($0)) }
            }

            Picker(l10n.t(.filterResolution), selection: $draft.resolution) {
                Text(l10n.t(.filterAny)).tag(ResolutionBucket?.none)
                ForEach(ResolutionBucket.allCases, id: \.self) {
                    Text(resolutionLabel($0)).tag(ResolutionBucket?.some($0))
                }
            }

            if !toolOptions.isEmpty {
                Picker(l10n.t(.filterTool), selection: $draft.tool) {
                    Text(l10n.t(.filterAny)).tag(String?.none)
                    ForEach(toolOptions, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
        }
    }

    // MARK: Novel-only

    private var novelSection: some View {
        Section(l10n.t(.searchTabNovel)) {
            if !genreOptions.isEmpty {
                Picker(l10n.t(.filterGenre), selection: $draft.genre) {
                    Text(l10n.t(.filterAny)).tag(Int?.none)
                    ForEach(genreOptions) { Text($0.label).tag(Int?.some($0.id)) }
                }
            }

            Picker(l10n.t(.filterLengthUnit), selection: $bodyUnit) {
                Text(l10n.t(.bodyUnitChars)).tag(BodyLengthUnit.characters)
                Text(l10n.t(.bodyUnitWords)).tag(BodyLengthUnit.words)
                Text(l10n.t(.bodyUnitReadingTime)).tag(BodyLengthUnit.readingTime)
            }
            .onChange(of: bodyUnit) { _, _ in syncBodyLength() }

            Picker(l10n.t(.filterLength), selection: $bodyBucket) {
                Text(l10n.t(.filterAny)).tag(-1)
                ForEach(Array(bodyUnit.buckets.enumerated()), id: \.offset) { idx, b in
                    Text(bodyBucketLabel(b)).tag(idx)
                }
            }
            .onChange(of: bodyBucket) { _, _ in syncBodyLength() }

            Toggle(l10n.t(.filterOriginalOnly), isOn: $draft.originalOnly)
            Toggle(l10n.t(.filterReplaceableOnly), isOn: $draft.replaceableOnly)
        }
    }

    // MARK: Dynamic options

    private var langOptions: [SearchOptionsResponse.LangOption] {
        (isNovelTab ? options?.novel?.lang : options?.illust?.lang)?.options
            ?? options?.illust?.lang?.options
            ?? options?.novel?.lang?.options
            ?? []
    }
    private var toolOptions: [String] { options?.illust?.tool?.options ?? [] }
    private var genreOptions: [SearchOptionsResponse.GenreOption] { options?.novel?.genre?.options ?? [] }

    /// Sorts offered for the active tab, always including the current value so the
    /// menu never renders blank if a shared illust-only sort is viewed on novel.
    private var sortChoices: [String] {
        var list = SortType.choices(isNovel: isNovelTab, isPremium: isPremium)
        if !list.contains(draft.sort) { list.append(draft.sort) }
        return list
    }

    /// Match targets for the active tab (illust: 3, novel: 4) — mirrors Shaft's
    /// per-type target lists rather than a shared union. The current value is kept
    /// so a cross-tab selection doesn't render the menu blank.
    private var targetChoices: [SearchTarget] {
        var list = isNovelTab ? SearchTarget.forNovel : SearchTarget.forIllust
        if !list.contains(draft.target) { list.append(draft.target) }
        return list
    }

    // MARK: Mutations

    private func resetDraft() {
        let f = SearchFilter.makeDefault(hideR18: MuteStore.shared.hideR18)
        draft = f
        dateChoice = DateChoice(filter: f)
        bodyUnit = .characters
        bodyBucket = -1
    }

    private func applyDateChoice(_ choice: DateChoice) {
        switch choice {
        case .any:
            draft.duration = nil; draft.startDate = nil; draft.endDate = nil
        case .custom:
            draft.duration = nil
            if draft.startDate == nil { draft.startDate = Date() }
            if draft.endDate == nil { draft.endDate = Date() }
        default:
            draft.duration = choice.bucket
            draft.startDate = nil; draft.endDate = nil
        }
    }

    private func syncBodyLength() {
        if bodyBucket < 0 || bodyBucket >= bodyUnit.buckets.count {
            draft.bodyLength = nil
        } else {
            let b = bodyUnit.buckets[bodyBucket]
            draft.bodyLength = BodyLength(unit: bodyUnit, min: b.min, max: b.max)
        }
    }

    private static func bucketIndex(of length: BodyLength?, unit: BodyLengthUnit) -> Int {
        guard let length else { return -1 }
        return unit.buckets.firstIndex { $0.min == length.min && $0.max == length.max } ?? -1
    }

    // MARK: Labels

    private func sortLabel(_ s: String) -> String {
        switch s {
        case SortType.dateDesc:         return l10n.t(.searchSortDateDesc)
        case SortType.dateAsc:          return l10n.t(.searchSortDateAsc)
        case SortType.popularDesc:      return l10n.t(.searchSortPopular)
        case SortType.popularMaleDesc:  return l10n.t(.sortPopularMale)
        case SortType.popularFemaleDesc: return l10n.t(.sortPopularFemale)
        default: return s
        }
    }

    private func targetLabel(_ t: SearchTarget) -> String {
        switch t {
        case .partialTags:  return l10n.t(.searchTargetPartial)
        case .exactTags:    return l10n.t(.searchTargetExact)
        case .titleCaption: return l10n.t(.searchTargetTitleCaption)
        case .novelText:    return l10n.t(.targetText)
        case .novelKeyword: return l10n.t(.targetKeyword)
        }
    }

    private func dateLabel(_ c: DateChoice) -> String {
        switch c {
        case .any:      return l10n.t(.searchDurationAll)
        case .day:      return l10n.t(.searchDurationDay)
        case .week:     return l10n.t(.searchDurationWeek)
        case .month:    return l10n.t(.searchDurationMonth)
        case .halfYear: return l10n.t(.durationHalfYear)
        case .year:     return l10n.t(.durationYear)
        case .custom:   return l10n.t(.filterCustomRange)
        }
    }

    private func ratioLabel(_ r: RatioPattern) -> String {
        switch r {
        case .landscape: return l10n.t(.ratioLandscape)
        case .portrait:  return l10n.t(.ratioPortrait)
        case .square:    return l10n.t(.ratioSquare)
        }
    }

    private func resolutionLabel(_ r: ResolutionBucket) -> String {
        switch r {
        case .above3000:         return "≥ 3000px"
        case .between1000And2999: return "1000–2999px"
        case .below1000:         return "≤ 999px"
        }
    }

    private func contentTypeLabel(_ t: IllustContentType) -> String {
        switch t {
        case .all:             return l10n.t(.filterAny)
        case .illustAndUgoira: return l10n.t(.typeIllust) + " + " + l10n.t(.typeUgoira)
        case .illust:          return l10n.t(.typeIllust)
        case .ugoira:          return l10n.t(.typeUgoira)
        case .manga:           return l10n.t(.profileManga)
        }
    }

    private func bodyBucketLabel(_ b: (min: Int?, max: Int?)) -> String {
        let suffix = bodyUnit == .readingTime ? " min" : ""
        switch (b.min, b.max) {
        case let (nil, max?):   return "≤ \(max)\(suffix)"
        case let (min?, nil):   return "≥ \(min)\(suffix)"
        case let (min?, max?):  return "\(min)–\(max)\(suffix)"
        default:                return l10n.t(.filterAny)
        }
    }
}

/// The seven post-date choices, flattening `SearchFilter`'s duration + custom range.
private enum DateChoice: Hashable, CaseIterable {
    case any, day, week, month, halfYear, year, custom

    init(filter: SearchFilter) {
        if let d = filter.duration {
            switch d {
            case .last24Hours:  self = .day
            case .lastWeek:     self = .week
            case .lastMonth:    self = .month
            case .lastHalfYear: self = .halfYear
            case .lastYear:     self = .year
            }
        } else if filter.startDate != nil || filter.endDate != nil {
            self = .custom
        } else {
            self = .any
        }
    }

    var bucket: DurationBucket? {
        switch self {
        case .day:      return .last24Hours
        case .week:     return .lastWeek
        case .month:    return .lastMonth
        case .halfYear: return .lastHalfYear
        case .year:     return .lastYear
        default:        return nil
        }
    }
}
