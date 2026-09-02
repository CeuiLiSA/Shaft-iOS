import SwiftUI

/// 收藏库的「筛选与排序」面板。
///
/// 1:1 移植自 `ceui.pixiv.ui.library.BookmarkFilterSheet`（bottom sheet + 声明式生成的各节）。
///
/// ## 交互取舍
///
/// - **即时生效，没有「取消」**：每点一下就写进 VM、命中数当场变，底部 CTA 只是
///   「看结果去」。筛选是探索行为，不是填表单——先看到结果变化再决定下一步，比
///   「攒一堆条件再提交、错了从头再来」快得多。要退回原样有标题行的「清空」。
/// - **标签点一下是「要」，长按是「不要」**：排除是低频但关键的动作（想看某个画师
///   但不想看某个系列），给它一个独立的按钮会让每个标签 chip 变成两个控件；藏在长按里
///   既不占地方，触发时又用危险色明确回显。
/// - **标签云是共现的**：列出来的标签永远是「在当前结果里还剩多少件」，所以一路往下
///   点绝不会点出 0 条结果——这正是 facet 检索比自由输入好用的地方。
struct BookmarkFilterSheet: View {
    let vm: BookmarkLibraryViewModel
    /// 宿主契约：条件变了让列表重刷。
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    /// 标签搜索框里的当前文本（只过滤已经算好的标签云，不打库）。
    @State private var tagQuery = ""

    /// 见过的标签名 → 展示名/译名。**被排除的标签不会出现在 facet 结果里**（facet 算的是
    /// 当前结果里还剩什么，而排除掉的东西按定义已经不在结果里了），没有这份缓存，用户
    /// 一旦长按排除某个标签就再也看不到那个 chip、也就没法取消排除。
    @State private var knownTagLabels: [String: (display: String, translated: String)] = [:]

    /// 标签云一次最多铺这么多 chip：再多一屏也看不完，还会把 sheet 撑得滚不到底。
    private static let tagChipLimit = 60

    /// 人气档位。用预设档而不是数字输入框：用户脑子里就是「几千收藏以上」这种量级。
    private static let popularitySteps: [Int?] = [nil, 500, 2_000, 10_000, 30_000]

    /// 小说字数档位。一万字上下大致是「一顿饭能看完」和「要分几次看」的分界。
    private static let lengthSteps: [Int?] = [nil, 5_000, 20_000, 50_000, 100_000]

    private var isIllust: Bool { vm.shelf.contentType == .illust }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.v3Border2)
                .frame(width: 32, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)

            HStack(alignment: .center) {
                Text(l10n.t(.bookmarkLibraryFilterTitle))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.v3Text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 「清空」放在标题行右侧而不是底部：它是**撤销**，跟底部的「确认」是相反意图，
                // 挨在一起最容易误触。
                BookmarkChip(label: l10n.t(.bookmarkLibraryFilterReset)) {
                    if vm.clearConditions() {
                        // 标签搜索框也要跟着空掉：条件已经清了，框里却还留着字，界面就在说谎。
                        tagQuery = ""
                        onChanged()
                    }
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .padding(.bottom, 12)

            Divider().overlay(Theme.v3Border1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sections
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            // 提交条：大圆角实底 CTA。文案永远带**实时命中数**——用户在上面每点一下，
            // 这个数就变一次，不用关掉 sheet 才知道自己筛出了什么。
            Button {
                dismiss()
            } label: {
                Text(applyText)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.brand, in: .rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(Theme.v3MenuBg)
    }

    private var applyText: String {
        if let count = vm.resultCount {
            return l10n.t(.bookmarkLibraryFilterApply, BookmarkLibraryFormat.count(count))
        }
        return l10n.t(.bookmarkLibraryFilterApplyPending)
    }

    // MARK: 各节

    @ViewBuilder
    private var sections: some View {
        let filter = vm.filter

        singleChoice(
            title: l10n.t(.bookmarkFilterSectionSort),
            options: sortOptions,
            selected: filter.sort
        ) { value in
            apply { f in
                f.sort = value
                // 随机每次重选都换一个种子，用户点第二下「随机」就是重新洗牌。
                if value.isRandom { f.randomSeed = BookmarkMirrorService.nowMs() }
            }
        }

        if isIllust {
            multiChoice(
                title: l10n.t(.bookmarkFilterSectionType),
                options: [
                    ("illust", l10n.t(.bookmarkFilterTypeIllust)),
                    ("manga", l10n.t(.bookmarkFilterTypeManga)),
                    ("ugoira", l10n.t(.bookmarkFilterTypeUgoira)),
                ],
                selected: Set(filter.workTypes)
            ) { values in
                apply { $0.workTypes = Array(values).sorted() }
            }

            multiChoice(
                title: l10n.t(.bookmarkFilterSectionShape),
                options: [
                    (BookmarkMirrorMapper.Orientation.landscape, l10n.t(.bookmarkFilterShapeLandscape)),
                    (BookmarkMirrorMapper.Orientation.portrait, l10n.t(.bookmarkFilterShapePortrait)),
                    (BookmarkMirrorMapper.Orientation.square, l10n.t(.bookmarkFilterShapeSquare)),
                ],
                selected: Set(filter.orientations)
            ) { values in
                apply { $0.orientations = Array(values).sorted() }
            }

            singleChoice(
                title: l10n.t(.bookmarkFilterSectionPages),
                options: [
                    (PageFilter.any, l10n.t(.bookmarkFilterAny)),
                    (PageFilter.singlePage, l10n.t(.bookmarkFilterPagesSingle)),
                    (PageFilter.multiPage, l10n.t(.bookmarkFilterPagesMulti)),
                ],
                selected: filter.pages
            ) { value in
                apply { $0.pages = value }
            }
        } else {
            // 小说侧「人气」之外最实用的那一维：想找长篇 / 想找一口气看完的短篇。
            singleChoice(
                title: l10n.t(.bookmarkFilterSectionLength),
                options: Self.lengthSteps.map { step in
                    (step, step.map { l10n.t(.bookmarkFilterLengthMin, BookmarkLibraryFormat.count($0)) } ?? l10n.t(.bookmarkFilterAny))
                },
                selected: filter.minTextLength
            ) { value in
                apply { $0.minTextLength = value }
            }
        }

        singleChoice(
            title: l10n.t(.bookmarkFilterSectionAge),
            options: [
                (AgeFilter.any, l10n.t(.bookmarkFilterAny)),
                (AgeFilter.allAges, l10n.t(.bookmarkFilterAgeAll)),
                (AgeFilter.r18, l10n.t(.bookmarkFilterAgeR18)),
                (AgeFilter.r18g, l10n.t(.bookmarkFilterAgeR18G)),
            ],
            selected: filter.age
        ) { value in
            apply { $0.age = value }
        }

        singleChoice(
            title: l10n.t(.bookmarkFilterSectionAI),
            options: [
                (AiFilter.any, l10n.t(.bookmarkFilterAny)),
                (AiFilter.excludeAI, l10n.t(.bookmarkFilterAIExclude)),
                (AiFilter.onlyAI, l10n.t(.bookmarkFilterAIOnly)),
            ],
            selected: filter.ai
        ) { value in
            apply { $0.ai = value }
        }

        singleChoice(
            title: l10n.t(.bookmarkFilterSectionState),
            options: [
                (ValidityFilter.any, l10n.t(.bookmarkFilterAny)),
                (ValidityFilter.validOnly, l10n.t(.bookmarkFilterStateValid)),
                // 「只看失效」是这张表白拿的能力：失效收藏平时混在几千件里根本找不出来，
                // 单独筛出来才谈得上清理。
                (ValidityFilter.invalidOnly, l10n.t(.bookmarkFilterStateInvalid)),
            ],
            selected: filter.validity
        ) { value in
            apply { $0.validity = value }
        }

        singleChoice(
            title: l10n.t(.bookmarkFilterSectionPopularity),
            options: Self.popularitySteps.map { step in
                (step, step.map { l10n.t(.bookmarkFilterPopularityMin, BookmarkLibraryFormat.count($0)) } ?? l10n.t(.bookmarkFilterAny))
            },
            selected: filter.minBookmarks
        ) { value in
            apply { $0.minBookmarks = value }
        }

        let years = vm.yearFacets
        if !years.isEmpty {
            singleChoice(
                title: l10n.t(.bookmarkFilterSectionYear),
                options: [(nil, l10n.t(.bookmarkFilterAny))] + years.map { facet in
                    (Optional(facet.year), l10n.t(.bookmarkFilterYearItem, "\(facet.year)", "\(facet.hitCount)"))
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

        toggleSection(
            title: l10n.t(.bookmarkFilterSectionSeries),
            label: l10n.t(.bookmarkFilterSeriesOnly),
            selected: filter.seriesOnly
        ) {
            apply { $0.seriesOnly.toggle() }
        }

        tagSection
        authorSection
    }

    /// 排序项。
    private var sortOptions: [(BookmarkSort, String)] {
        var list: [BookmarkSort] = [.bookmarkNewest, .bookmarkOldest, .createdNewest, .createdOldest, .popularDesc, .popularAsc, .viewsDesc]
        if isIllust {
            list.append(.pagesDesc)
        } else {
            list.append(.lengthDesc)
            list.append(.lengthAsc)
        }
        list.append(.titleAsc)
        list.append(.random)
        return list.map { ($0, l10n.t(BookmarkSortLabels.key($0))) }
    }

    // MARK: 标签

    private var tagSection: some View {
        let filter = vm.filter
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(l10n.t(.bookmarkFilterSectionTags))
            sectionHint(l10n.t(.bookmarkFilterTagHint))

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.v3Text3).font(.system(size: 12))
                    TextField(l10n.t(.bookmarkFilterTagSearchHint), text: $tagQuery)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text1)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.v3Surface2, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.v3Border1, lineWidth: 1))
                // 「同时满足 / 任一满足」：多标签的默认意图是收窄（AND），但「这几个系列随便哪个都行」
                // 也是真实需求，一个 chip 就能表达，不值得为它做二级菜单。
                BookmarkChip(
                    label: l10n.t(filter.tagMatchAll ? .bookmarkFilterTagModeAll : .bookmarkFilterTagModeAny),
                    activated: filter.tagNames.count > 1
                ) {
                    apply { $0.tagMatchAll.toggle() }
                }
            }
            .padding(.top, 8)

            let entries = tagEntries
            if entries.isEmpty {
                sectionHint(l10n.t(.bookmarkFilterTagEmpty))
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(entries.prefix(Self.tagChipLimit), id: \.tagName) { entry in
                        let included = filter.tagNames.contains(entry.tagName)
                        let excluded = filter.excludedTagNames.contains(entry.tagName)
                        BookmarkChip(
                            label: tagLabel(entry, excluded: excluded),
                            activated: included,
                            excluded: excluded,
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
                .padding(.top, 8)
            }
        }
        .onChange(of: vm.tagFacets, initial: true) { _, facets in
            for facet in facets { knownTagLabels[facet.tagName] = (facet.displayName, facet.translatedName) }
        }
    }

    /// 标签云里的一枚 chip。`hitCount` 为 nil = 被排除的「幽灵项」，它已经不在结果里了。
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
        // 排除掉的标签不在 facet 里（见 knownTagLabels），得自己补一份「幽灵 chip」出来，
        // 否则排除就是个单向操作，取消不掉。
        for name in filter.excludedTagNames {
            let known = knownTagLabels[name] ?? facets.first(where: { $0.tagName == name }).map { ($0.displayName, $0.translatedName) }
            entries.append(TagChipEntry(
                tagName: name, displayName: known?.display ?? name, translatedName: known?.translated ?? "",
                hitCount: nil, excluded: true
            ))
        }
        // facet 是异步算出来的：排除刚点下去、旧 facet 还没换掉的那一拍里，同一个标签会同时
        // 以幽灵 chip 和 facet 出现 —— ForEach 的 id 撞了就是渲染错乱。以幽灵为准去重。
        var seen = Set(entries.map(\.tagName))
        for facet in facets where seen.insert(facet.tagName).inserted {
            entries.append(TagChipEntry(
                tagName: facet.tagName, displayName: facet.displayName, translatedName: facet.translatedName,
                hitCount: facet.hitCount, excluded: false
            ))
        }
        // 已选中的钉在最前：标签云会随着每次下钻整体重排，选中的 chip 一旦被挤到
        // 几十个之后，用户就找不到自己刚点了什么、也退不回去了。
        let selected = Set(filter.tagNames)
        let pinned = entries.filter { $0.excluded || selected.contains($0.tagName) }
        let rest = entries.filter { !($0.excluded || selected.contains($0.tagName)) }
        let query = tagQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return (pinned + rest).filter { entry in
            query.isEmpty || entry.tagName.contains(query) || entry.translatedName.lowercased().contains(query)
        }
    }

    private func tagLabel(_ entry: TagChipEntry, excluded: Bool) -> String {
        var label = excluded ? "−" : ""
        label += entry.displayName
        if !entry.translatedName.isEmpty, entry.translatedName != entry.displayName {
            label += " · " + entry.translatedName
        }
        if let hits = entry.hitCount { label += "  \(hits)" }
        return label
    }

    // MARK: 作者

    private var authorSection: some View {
        let filter = vm.filter
        let facets = vm.authorFacets
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(l10n.t(.bookmarkFilterSectionAuthor))
            if facets.isEmpty {
                sectionHint(l10n.t(.bookmarkFilterAuthorEmpty))
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(facets) { facet in
                        let selected = filter.authorIds.contains(facet.authorId)
                        BookmarkChip(label: "\(facet.authorName)  \(facet.hitCount)", activated: selected) {
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
                .padding(.top, 8)
            }
        }
    }

    // MARK: 声明式的节构造器

    private func singleChoice<T: Hashable>(
        title: String,
        options: [(T, String)],
        selected: T,
        apply: @escaping (T) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            FlowLayout(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    BookmarkChip(label: option.1, activated: option.0 == selected) {
                        apply(option.0)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func multiChoice<T: Hashable>(
        title: String,
        options: [(T, String)],
        selected: Set<T>,
        apply: @escaping (Set<T>) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            FlowLayout(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    BookmarkChip(label: option.1, activated: selected.contains(option.0)) {
                        var next = selected
                        if next.contains(option.0) { next.remove(option.0) } else { next.insert(option.0) }
                        apply(next)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func toggleSection(title: String, label: String, selected: Bool, toggle: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            FlowLayout(spacing: 8) {
                BookmarkChip(label: label, activated: selected) { toggle() }
            }
            .padding(.top, 8)
        }
    }

    // MARK: 零件

    private func apply(_ transform: (inout BookmarkFilter) -> Void) {
        if vm.updateFilter(transform) { onChanged() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(Theme.v3Text3)
            .padding(.top, 14)
    }

    private func sectionHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.v3Text3)
            .padding(.top, 4)
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
