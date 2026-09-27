import SwiftUI
import UIKit

/// 本地库（收藏 / 关注）的「筛选与排序」面板。V3 + MD3-E（2026-09-25 重做）。
///
/// 1:1 移植自 `ceui.pixiv.ui.library.BookmarkFilterSheet` + 零件 `LibraryFilterViews`。
///
/// ## 版式
///
/// 照规范的 Sheet 配方：标题 → 当前状态（书架总数 · 开了几项筛选）→ 条件 → 主操作。
/// 条件按「排序 / 作品 / 人气与时间 / 标签 / 作者」分进几张 22pt 分组卡，卡内一行一个维度；
/// 互斥的档位是连通选择组，可叠加的是带勾的胶囊，开关是开关行 —— 控件形状本身就说明了
/// 「只能选一个 / 可以选几个 / 开或关」，不用再靠文字解释。
///
/// 哪几节出现由书架的 `LibraryProfile` 决定：关注书架里一行是一个人，没有分级、人气、作者
/// 这些作品维度，只留排序、最近投稿年份和（取自最近作品的）标签。
///
/// ## 交互取舍
///
/// - **即时生效，没有「取消」**：每点一下就写进 VM、命中数当场变，底部主操作只是
///   「看结果去」。筛选是探索行为，不是填表单。要退回原样有标题行的「清空」。
/// - **标签点一下是「要」，长按是「不要」**：排除是低频但关键的动作，给它独立按钮会让每个
///   标签变成两个控件；藏在长按里，触发时用危险色明确回显。
/// - **标签云是共现的**：列出来的永远是「在当前结果里还剩多少件」，一路往下点绝不会点出 0 条。
struct BookmarkFilterSheet: View {
    let vm: BookmarkLibraryViewModel
    /// 宿主契约：条件变了让列表重刷。
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    /// 标签搜索框里的当前文本（只过滤已经算好的标签云，不打库）。
    @State private var tagQuery = ""

    /// 见过的标签名 → 展示名/译名。**被排除的标签不会出现在 facet 结果里**（facet 算的是
    /// 当前结果里还剩什么），没有这份缓存，用户一旦长按排除某个标签就再也看不到那个胶囊、
    /// 也就没法取消排除。
    @State private var knownTagLabels: [String: (display: String, translated: String)] = [:]

    /// 标签云一次最多铺这么多胶囊：再多一屏也看不完，还会把 sheet 撑得滚不到底。
    private static let tagChipLimit = 60
    /// 人气档位。用预设档而不是数字输入框：用户脑子里就是「几千收藏以上」这种量级。
    private static let popularitySteps: [Int?] = [nil, 500, 2_000, 10_000, 30_000]
    /// 小说字数档位。一万字上下大致是「一顿饭能看完」和「要分几次看」的分界。
    private static let lengthSteps: [Int?] = [nil, 5_000, 20_000, 50_000, 100_000]
    /// 没有可清的条件时「清空」的透明度：看得见在哪，但明确点不了。
    private static let disabledAlpha = 0.38

    private var profile: LibraryProfile { LibraryProfile.of(vm.shelf.contentType) }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.v3Border2)
                .frame(width: 32, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .accessibilityHidden(true)

            header

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sections
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                }
            )

            Theme.v3Border1.frame(height: 1)

            // 主操作：整宽实色胶囊。文案永远带**实时命中数**——上面每点一下这个数就变一次，
            // 不用关掉 sheet 才知道自己筛出了什么。
            Button { dismiss() } label: {
                Text(applyText)
            }
            .buttonStyle(LibraryPrimaryActionStyle())
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(Theme.v3Bg)
        .onChange(of: vm.tagFacets, initial: true) { _, facets in
            for facet in facets { knownTagLabels[facet.tagName] = (facet.displayName, facet.translatedName) }
        }
    }

    // MARK: 标题行

    /// 标题（22 Montserrat Bold）+ 当前状态（「共 N 件 · 已启用 K 项筛选」13 Medium `v3_text_2`）；
    /// 「清空」是标题行末端的浅色胶囊 —— 它是撤销，跟底部的确认是相反意图，挨在一起最容易误触。
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t(.bookmarkLibraryFilterTitle))
                    .font(.montserratBold(22))
                    .foregroundStyle(Theme.v3Text1)
                    .accessibilityAddTraits(.isHeader)
                Text(summaryText)
                    .font(.montserratMedium(13))
                    .foregroundStyle(Theme.v3Text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let canReset = vm.filter.hasAnyCondition
            Button {
                if vm.clearConditions() {
                    // 标签搜索框也要跟着空掉：条件已经清了，框里却还留着字，界面就在说谎。
                    tagQuery = ""
                    onChanged()
                }
            } label: {
                Text(l10n.t(.bookmarkLibraryFilterReset))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.v3TextAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Theme.brand.opacity(0.20)))
                    .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.30), lineWidth: 0.5))
                    .padding(.vertical, 6)
                    .contentShape(.rect)
            }
            .buttonStyle(LibraryPressScaleStyle())
            .disabled(!canReset)
            .opacity(canReset ? 1 : Self.disabledAlpha)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var summaryText: String {
        let conditions = vm.filter.conditionCount
        let active = conditions > 0
            ? String(format: l10n.t(.bookmarkFilterActiveCount), conditions)
            : l10n.t(.bookmarkFilterNoneActive)
        guard let total = vm.totalCount else { return active }
        return "\(l10n.t(profile.totalCount, BookmarkLibraryFormat.count(total))) · \(active)"
    }

    private var applyText: String {
        if let count = vm.resultCount {
            return l10n.t(profile.showResults, BookmarkLibraryFormat.count(count))
        }
        return l10n.t(.bookmarkLibraryFilterApplyPending)
    }

    // MARK: 各组

    @ViewBuilder
    private var sections: some View {
        let filter = vm.filter
        let profile = profile
        let years = vm.yearFacets

        groupHeader(l10n.t(.bookmarkFilterSectionSort), first: true)
        groupCard {
            row(title: nil, divider: false) {
                segmented(profile.sorts.map { ($0, l10n.t(profile.sortLabel($0))) }, selected: filter.sort) { value in
                    apply { f in
                        f.sort = value
                        // 随机每次重选都换一个种子，用户点第二下「随机」就是重新洗牌。
                        if value.isRandom { f.randomSeed = BookmarkMirrorService.nowMs() }
                    }
                }
            }
        }

        if profile.hasWorkFilters {
            groupHeader(l10n.t(.bookmarkFilterGroupWorks), first: false)
            groupCard { workRows(profile: profile, filter: filter) }
        }

        // 一组里一行都没有（关注书架还没有年份）就整组不出。
        if profile.hasWorkFilters || !years.isEmpty {
            groupHeader(l10n.t(profile.hasWorkFilters ? .bookmarkFilterGroupPopularityTime : .bookmarkFilterGroupTime), first: false)
            groupCard {
                if profile.hasWorkFilters {
                    row(title: l10n.t(.bookmarkFilterSectionPopularity), divider: false) {
                        segmented(
                            Self.popularitySteps.map { step in
                                (step, step.map { l10n.t(.bookmarkFilterPopularityMin, BookmarkLibraryFormat.count($0)) } ?? l10n.t(.bookmarkFilterAny))
                            },
                            selected: filter.minBookmarks
                        ) { value in apply { $0.minBookmarks = value } }
                    }
                }
                if !years.isEmpty {
                    row(title: l10n.t(profile.yearSection), divider: profile.hasWorkFilters) {
                        segmented(
                            [(Int?.none, l10n.t(.bookmarkFilterAny))] + years.map { facet in
                                (Optional(facet.year), l10n.t(.bookmarkFilterYearItem, "\(facet.year)", BookmarkLibraryFormat.count(facet.hitCount)))
                            },
                            selected: filter.createdFromMs.map(Self.yearOf)
                        ) { year in
                            apply { f in
                                if let year {
                                    f.createdFromMs = Self.yearStartMs(year)
                                    f.createdToMs = Self.yearStartMs(year + 1) - 1
                                } else {
                                    f.createdFromMs = nil
                                    f.createdToMs = nil
                                }
                            }
                        }
                    }
                }
                if profile.hasWorkFilters {
                    row(title: nil, divider: true) {
                        LibrarySwitchRow(title: l10n.t(.bookmarkFilterSeriesOnly), isOn: filter.seriesOnly) {
                            apply { $0.seriesOnly.toggle() }
                        }
                    }
                }
            }
        }

        groupHeader(l10n.t(.bookmarkFilterSectionTags), first: false)
        groupCard { tagRows(profile: profile, filter: filter) }

        if profile.hasWorkFilters {
            groupHeader(l10n.t(.bookmarkFilterSectionAuthor), first: false)
            groupCard { authorRow(filter: filter) }
        }
    }

    /// 作品维度：类型 / 画幅 / 页数（插画）或字数（小说），以及分级 / AI / 作品状态。
    @ViewBuilder
    private func workRows(profile: LibraryProfile, filter: BookmarkFilter) -> some View {
        if profile.isIllust {
            row(title: l10n.t(.bookmarkFilterSectionType), divider: false) {
                multiChoice(
                    [
                        ("illust", l10n.t(.bookmarkFilterTypeIllust)),
                        ("manga", l10n.t(.bookmarkFilterTypeManga)),
                        ("ugoira", l10n.t(.bookmarkFilterTypeUgoira)),
                    ],
                    selected: Set(filter.workTypes)
                ) { values in apply { $0.workTypes = Array(values).sorted() } }
            }
            row(title: l10n.t(.bookmarkFilterSectionShape), divider: true) {
                multiChoice(
                    [
                        (BookmarkMirrorMapper.Orientation.landscape, l10n.t(.bookmarkFilterShapeLandscape)),
                        (BookmarkMirrorMapper.Orientation.portrait, l10n.t(.bookmarkFilterShapePortrait)),
                        (BookmarkMirrorMapper.Orientation.square, l10n.t(.bookmarkFilterShapeSquare)),
                    ],
                    selected: Set(filter.orientations)
                ) { values in apply { $0.orientations = Array(values).sorted() } }
            }
            row(title: l10n.t(.bookmarkFilterSectionPages), divider: true) {
                segmented(
                    [
                        (PageFilter.any, l10n.t(.bookmarkFilterAny)),
                        (PageFilter.singlePage, l10n.t(.bookmarkFilterPagesSingle)),
                        (PageFilter.multiPage, l10n.t(.bookmarkFilterPagesMulti)),
                    ],
                    selected: filter.pages
                ) { value in apply { $0.pages = value } }
            }
        }
        if profile.isNovel {
            // 小说侧「人气」之外最实用的那一维：想找长篇 / 想找一口气看完的短篇。
            row(title: l10n.t(.bookmarkFilterSectionLength), divider: false) {
                segmented(
                    Self.lengthSteps.map { step in
                        (step, step.map { l10n.t(.bookmarkFilterLengthMin, BookmarkLibraryFormat.count($0)) } ?? l10n.t(.bookmarkFilterAny))
                    },
                    selected: filter.minTextLength
                ) { value in apply { $0.minTextLength = value } }
            }
        }
        row(title: l10n.t(.bookmarkFilterSectionAge), divider: true) {
            segmented(
                [
                    (AgeFilter.any, l10n.t(.bookmarkFilterAny)),
                    (AgeFilter.allAges, l10n.t(.bookmarkFilterAgeAll)),
                    (AgeFilter.r18, l10n.t(.bookmarkFilterAgeR18)),
                    (AgeFilter.r18g, l10n.t(.bookmarkFilterAgeR18G)),
                ],
                selected: filter.age
            ) { value in apply { $0.age = value } }
        }
        row(title: l10n.t(.bookmarkFilterSectionAI), divider: true) {
            segmented(
                [
                    (AiFilter.any, l10n.t(.bookmarkFilterAny)),
                    (AiFilter.excludeAI, l10n.t(.bookmarkFilterAIExclude)),
                    (AiFilter.onlyAI, l10n.t(.bookmarkFilterAIOnly)),
                ],
                selected: filter.ai
            ) { value in apply { $0.ai = value } }
        }
        row(title: l10n.t(.bookmarkFilterSectionState), divider: true) {
            segmented(
                [
                    (ValidityFilter.any, l10n.t(.bookmarkFilterAny)),
                    (ValidityFilter.validOnly, l10n.t(.bookmarkFilterStateValid)),
                    // 「只看失效」是这张表白拿的能力：失效收藏平时混在几千件里根本找不出来，
                    // 单独筛出来才谈得上清理。
                    (ValidityFilter.invalidOnly, l10n.t(.bookmarkFilterStateInvalid)),
                ],
                selected: filter.validity
            ) { value in apply { $0.validity = value } }
        }
    }

    // MARK: 标签

    /// 标签组：规则说明 + 搜索框 +（选了两个以上才出现的）匹配方式 + 标签云。
    @ViewBuilder
    private func tagRows(profile: LibraryProfile, filter: BookmarkFilter) -> some View {
        row(title: nil, hint: l10n.t(profile.tagHint), divider: false) {
            LibrarySearchField(hint: l10n.t(.bookmarkFilterTagSearchHint), text: $tagQuery)
        }
        // 「同时满足 / 任一满足」只在选了两个以上标签时才有意义，之前出现只是噪音。
        if filter.tagNames.count > 1 {
            row(title: l10n.t(.bookmarkFilterTagModeLabel), divider: false) {
                segmented(
                    [(true, l10n.t(.bookmarkFilterTagModeAll)), (false, l10n.t(.bookmarkFilterTagModeAny))],
                    selected: filter.tagMatchAll
                ) { value in apply { $0.tagMatchAll = value } }
            }
        }
        row(title: nil, divider: false) {
            let entries = tagEntries
            if entries.isEmpty {
                libraryHint(l10n.t(.bookmarkFilterTagEmpty))
            } else {
                LibraryFlow(hSpacing: 8, vSpacing: 0) {
                    ForEach(entries.prefix(Self.tagChipLimit), id: \.tagName) { entry in
                        let included = filter.tagNames.contains(entry.tagName)
                        let excluded = filter.excludedTagNames.contains(entry.tagName)
                        LibraryFilterChip(
                            label: tagLabel(entry),
                            count: entry.hitCount,
                            state: excluded ? .excluded : included ? .selected : .idle,
                            onTap: {
                                apply { current in
                                    // 点击在「不选 → 包含 → 不选」之间转；排除态点一下直接回到不选
                                    if excluded {
                                        current.excludedTagNames.removeAll { $0 == entry.tagName }
                                    } else if included {
                                        current.tagNames.removeAll { $0 == entry.tagName }
                                    } else {
                                        current.tagNames.append(entry.tagName)
                                    }
                                }
                            },
                            onLongPress: {
                                apply { current in
                                    if excluded {
                                        current.excludedTagNames.removeAll { $0 == entry.tagName }
                                    } else {
                                        current.tagNames.removeAll { $0 == entry.tagName }
                                        current.excludedTagNames.append(entry.tagName)
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    /// 标签云里的一枚胶囊。`hitCount` 为 nil = 被排除的「幽灵项」，它已经不在结果里了。
    private struct TagChipEntry {
        let tagName: String
        let displayName: String
        let translatedName: String
        let hitCount: Int?
        let excluded: Bool
    }

    private var tagEntries: [TagChipEntry] {
        let filter = vm.filter
        let facets = vm.tagFacets
        var entries: [TagChipEntry] = []
        // 排除掉的标签不在 facet 里（见 knownTagLabels），得自己补一份「幽灵胶囊」出来，
        // 否则排除就是个单向操作，取消不掉。
        for name in filter.excludedTagNames {
            let known = knownTagLabels[name] ?? facets.first(where: { $0.tagName == name }).map { ($0.displayName, $0.translatedName) }
            entries.append(TagChipEntry(
                tagName: name, displayName: known?.display ?? name, translatedName: known?.translated ?? "",
                hitCount: nil, excluded: true
            ))
        }
        // facet 是异步算出来的：排除刚点下去、旧 facet 还没换掉的那一拍里，同一个标签会同时
        // 以幽灵胶囊和 facet 出现 —— ForEach 的 id 撞了就是渲染错乱。以幽灵为准去重。
        var seen = Set(entries.map(\.tagName))
        for facet in facets where seen.insert(facet.tagName).inserted {
            entries.append(TagChipEntry(
                tagName: facet.tagName, displayName: facet.displayName, translatedName: facet.translatedName,
                hitCount: facet.hitCount, excluded: false
            ))
        }
        // 已选中的钉在最前：标签云会随着每次下钻整体重排，选中的胶囊一旦被挤到
        // 几十个之后，用户就找不到自己刚点了什么、也退不回去了。
        let selected = Set(filter.tagNames)
        let pinned = entries.filter { $0.excluded || selected.contains($0.tagName) }
        let rest = entries.filter { !($0.excluded || selected.contains($0.tagName)) }
        let query = tagQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return (pinned + rest).filter { entry in
            query.isEmpty || entry.tagName.contains(query) || entry.translatedName.lowercased().contains(query)
        }
    }

    private func tagLabel(_ entry: TagChipEntry) -> String {
        var label = entry.displayName
        if !entry.translatedName.isEmpty, entry.translatedName != entry.displayName {
            label += " · " + entry.translatedName
        }
        return label
    }

    // MARK: 作者

    @ViewBuilder
    private func authorRow(filter: BookmarkFilter) -> some View {
        let facets = vm.authorFacets
        row(title: nil, divider: false) {
            if facets.isEmpty {
                libraryHint(l10n.t(.bookmarkFilterAuthorEmpty))
            } else {
                LibraryFlow(hSpacing: 8, vSpacing: 0) {
                    ForEach(facets) { facet in
                        let selected = filter.authorIds.contains(facet.authorId)
                        LibraryFilterChip(label: facet.authorName, count: facet.hitCount, state: selected ? .selected : .idle) {
                            apply { current in
                                if selected {
                                    current.authorIds.removeAll { $0 == facet.authorId }
                                } else {
                                    current.authorIds.append(facet.authorId)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 声明式的构造器

    /// 卡片外的分组标题：13 / 700 `v3_text_2`，比卡内行标题弱一档，只负责把卡片分成几块。
    private func groupHeader(_ text: String, first: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .tracking(13 * 0.04)
            .foregroundStyle(Theme.v3Text2)
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, 8)
            .padding(.top, first ? 8 : 24)
            .padding(.bottom, 8)
    }

    /// 22pt 分组卡：cardFill + hairline，里面按行排。
    private func groupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.v3CardFill))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.v3CardHairline, lineWidth: 0.5))
    }

    /// 卡片里的一行：（行与行之间的 hairline）+ 行标题 15 / 600 +（可选的一句说明 12 `v3_text_2`）+ 控件。
    private func row<Control: View>(
        title: String?,
        hint: String? = nil,
        divider: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if divider {
                Theme.v3CardHairline.frame(height: 0.5).padding(.top, 12)
            }
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.v3Text1)
                    .padding(.top, 14)
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.v3Text2)
                    .lineSpacing(12 * 0.3)
                    .padding(.top, 4)
            }
            control()
                .padding(.top, title == nil && hint == nil ? 12 : 10)
        }
    }

    private func libraryHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.v3Text2)
            .lineSpacing(13 * 0.3)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmented<T: Hashable>(_ options: [(T, String)], selected: T, onSelect: @escaping (T) -> Void) -> some View {
        LibrarySegmentedGroup(labels: options.map(\.1), selectedIndex: options.firstIndex { $0.0 == selected }) { index in
            onSelect(options[index].0)
        }
    }

    private func multiChoice<T: Hashable>(_ options: [(T, String)], selected: Set<T>, apply: @escaping (Set<T>) -> Void) -> some View {
        LibraryFlow(hSpacing: 8, vSpacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                LibraryFilterChip(label: option.1, count: nil, state: selected.contains(option.0) ? .selected : .idle) {
                    var next = selected
                    if next.contains(option.0) { next.remove(option.0) } else { next.insert(option.0) }
                    apply(next)
                }
            }
        }
    }

    // MARK: 零件

    private func apply(_ transform: (inout BookmarkFilter) -> Void) {
        if vm.updateFilter(transform) { onChanged() }
    }

    private static func yearOf(_ epochMs: Int64) -> Int {
        Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000))
    }

    private static func yearStartMs(_ year: Int) -> Int64 {
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        let date = Calendar.current.date(from: comps) ?? Date(timeIntervalSince1970: 0)
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

// MARK: - LibraryFilterViews 的 V3 零件

/// 选中态的主题浅色容器：20% 主色**不透明合成**在卡片底上（字色按它校正）。
private enum LibraryFilterColors {
    static let selectedFill = Color(uiColor: UIColor { traits in
        let card = UIColor(Theme.v3CardFill).resolvedColor(with: traits)
        let brand = UIColor(Theme.brand)
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        brand.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        card.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let a: CGFloat = 0.20
        return UIColor(red: fr * a + br * (1 - a), green: fg * a + bg * (1 - a), blue: fb * a + bb * (1 - a), alpha: 1)
    })
    static let selectedStroke = Theme.brand.opacity(0.30)
    static let selectedText = Theme.v3TagText
    static let fade = Animation.easeInOut(duration: 0.18)
}

/// 连通选择组（`.v3-filters` 的原生版）。选项不多（≤ 4）时等分整行 —— 分级、AI 这类互斥档位
/// 一眼看出「只能选一个」；选项多（排序、年份、人气档）时在同一条轨道里换行排开。
/// 轨道 `v3_surface_2` 24pt 圆角，左右 4pt 内边距；每一项热区 48pt，可见的选中底色只有 40pt。
private struct LibrarySegmentedGroup: View {
    let labels: [String]
    let selectedIndex: Int?
    let onSelect: (Int) -> Void

    private static let equalLimit = 4

    var body: some View {
        Group {
            if labels.count <= Self.equalLimit {
                HStack(spacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        segment(label, index: index, fill: true)
                    }
                }
            } else {
                LibraryFlow(hSpacing: 0, vSpacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        segment(label, index: index, fill: false)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.v3Surface2))
    }

    /// `fill`: 等分整行时每一项撑满自己那一格；换行排布时按内容宽度。
    private func segment(_ label: String, index: Int, fill: Bool) -> some View {
        let chosen = index == selectedIndex
        return Button { onSelect(index) } label: {
            Text(label)
                .font(.system(size: 14, weight: chosen ? .semibold : .medium))
                .foregroundStyle(chosen ? LibraryFilterColors.selectedText : Theme.v3Text2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: 40)
                .background {
                    if chosen {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LibraryFilterColors.selectedFill)
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(LibraryFilterColors.selectedStroke, lineWidth: 0.5))
                    }
                }
                .padding(.vertical, 4)
                .contentShape(.rect)
                .animation(LibraryFilterColors.fade, value: chosen)
        }
        .buttonStyle(LibraryPressScaleStyle())
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// 可多选的筛选胶囊：可见 36pt（上下 6pt 透明沿补足 48pt 热区），18pt 圆角。
/// 未选中性浅底；选中换成同一种主题浅色容器并在前面带一个勾 —— 勾是「可以再选一个」的信号；
/// 排除用日夜 `v3_danger` 的语义色 + 减号，不随主题色变。计数是小一号的 `v3_text_2` 次级小标。
private struct LibraryFilterChip: View {
    enum ChipState { case idle, selected, excluded }

    let label: String
    let count: Int?
    let state: ChipState
    let onTap: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        let textColor: Color = {
            switch state {
            case .idle: return Theme.v3Text1
            case .selected: return LibraryFilterColors.selectedText
            case .excluded: return Theme.v3Danger
            }
        }()
        HStack(spacing: 6) {
            switch state {
            case .selected:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).frame(width: 16, height: 16)
            case .excluded:
                Image(systemName: "minus.circle").font(.system(size: 14)).frame(width: 16, height: 16)
            case .idle:
                EmptyView()
            }
            (Text(label) + countText)
                .font(.system(size: 14, weight: state == .selected ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(background)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .animation(LibraryFilterColors.fade, value: state)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) { onLongPress?() }
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
    }

    private var countText: Text {
        guard let count else { return Text("") }
        return Text("  " + BookmarkLibraryFormat.count(count))
            .font(.system(size: 14 * 0.86))
            .foregroundColor(Theme.v3Text2)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        switch state {
        case .idle:
            shape.fill(Theme.v3Surface2)
        case .selected:
            shape.fill(LibraryFilterColors.selectedFill)
                .overlay(shape.strokeBorder(LibraryFilterColors.selectedStroke, lineWidth: 0.5))
        case .excluded:
            shape.fill(Theme.v3Danger.opacity(0x24 / 255))
                .overlay(shape.strokeBorder(Theme.v3Danger.opacity(0x66 / 255), lineWidth: 0.5))
        }
    }
}

/// 开关行：标题在左、开关在右，整行都是热区（最小 56pt）。
private struct LibrarySwitchRow: View {
    let title: String
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.v3Text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: .constant(isOn))
                    .labelsHidden()
                    .tint(Theme.brand)
                    .allowsHitTesting(false)
            }
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(.isButton)
    }
}

/// 卡片内的搜索框：中性浅底 16pt 圆角，48pt 高，放大镜在起始侧。
private struct LibrarySearchField: View {
    let hint: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Theme.v3Text2)
                .frame(width: 20, height: 20)
            TextField(text: $text) {
                Text(hint).foregroundStyle(Theme.v3Text2)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.v3Text1)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.v3Surface2))
    }
}

/// 底部主操作：整宽 56pt 实色胶囊，按下时圆角收到 15pt（V3 的形状反馈）+ 缩到 0.96。
private struct LibraryPrimaryActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: pressed ? 15 : 28, style: .continuous).fill(Theme.brand))
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.18), value: pressed)
    }
}

/// 按下缩到 0.96（系统关动画时不缩）。
private struct LibraryPressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 换行排布（FlexboxLayout wrap）：横向 / 纵向间距分开给 —— 胶囊自带 6pt 透明沿，行距不需要再加。
private struct LibraryFlow: Layout {
    let hSpacing: CGFloat
    let vSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x + size.width > maxWidth, x > 0 {
                y += rowH + vSpacing
                x = 0
                rowH = 0
            }
            x += size.width + hSpacing
            widest = max(widest, x - hSpacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowH + vSpacing
                x = bounds.minX
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + hSpacing
            rowH = max(rowH, size.height)
        }
    }
}
