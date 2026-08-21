import SwiftUI

// MARK: - Every tag an author has ever used (web ajax)

/// `/ajax/user/{id}/{category}/tags` row — upstream `UserWorkTag`.
struct UserWorkTag: Identifiable, Hashable, Sendable {
    let tag: String
    let translation: String?
    let count: Int

    var id: String { tag }
    /// Pre-folded for filtering: recomputing `lowercased()` for ~2000 rows on
    /// every keystroke is pure allocation churn.
    let rawLower: String
    let translationLower: String

    init(tag: String, translation: String?, count: Int) {
        self.tag = tag
        self.translation = translation
        self.count = count
        // ROOT-equivalent folding: a Turkish locale would fold "I" to "ı" and
        // silently break Latin matching.
        self.rawLower = tag.lowercased()
        self.translationLower = (translation ?? "").lowercased()
    }
}

enum UserWorkTagsAPI {
    /// `all=1` returns a few more tags than the default; `lang` decides whether
    /// `tag_translation` is populated.
    static func fetch(userId: Int64, category: String, lang: String) async -> [UserWorkTag]? {
        guard let url = URL(
            string: "https://www.pixiv.net/ajax/user/\(userId)/\(category)/tags?all=1&lang=\(lang)"
        ) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("https://www.pixiv.net/users/\(userId)", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await DirectConnection.data(
                  for: req, using: DirectConnection.shared,
                  directConnect: DirectConnection.isEnabledAtLaunch),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["error"] as? Bool) != true,
              let body = root["body"] as? [[String: Any]]
        else { return nil }

        return body.compactMap { row in
            guard let tag = row["tag"] as? String,
                  !tag.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return UserWorkTag(
                tag: tag,
                translation: row["tag_translation"] as? String,
                count: (row["cnt"] as? Int) ?? 0
            )
        }
    }

    /// App locale → pixiv `lang`. Upstream hardcodes "zh"; sending the reader's
    /// own language just makes `tag_translation` useful to them.
    static func lang(for tag: String) -> String {
        switch tag {
        case "zh-Hans": return "zh"
        case "zh-Hant": return "zh_tw"
        default: return String(tag.prefix(2))
        }
    }
}

// MARK: - 高级搜索 sheet (UserTagSearchSheet)

/// The author's full tag list, searchable, sorted by use count. The filter-bar
/// chips come from the first page of works (app API); this sheet is the "I know
/// the tag, find it" answer and can list a couple of thousand rows.
struct UserTagSearchSheet: View {
    let userId: Int64
    let category: String
    /// The pushed destination is owned by the presenting tab: a sheet has no
    /// navigation stack of its own to push onto.
    var onPick: (UserWorkTag) -> Void = { _ in }

    @State private var all: [UserWorkTag] = []
    @State private var query = ""
    @State private var loaded = false
    @State private var isLoading = true
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    private var shown: [UserWorkTag] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        // Raw *and* translation match: the reader may remember either.
        return all.filter { $0.rawLower.contains(q) || $0.translationLower.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            content
        }
        .background(Theme.v3Bg)
        .presentationDetents([.fraction(0.92)])
        .presentationDragIndicator(.visible)
        .task {
            guard !loaded else { return }
            let rows = await UserWorkTagsAPI.fetch(
                userId: userId, category: category,
                lang: UserWorkTagsAPI.lang(for: l10n.activeTag)
            )
            isLoading = false
            guard let rows else {
                // Only a network/parse failure lands here; an empty list is a
                // legitimate result and gets the "no tags" copy instead.
                failed = true
                return
            }
            // The server returns no useful order — sort by count desc, then by
            // name so repeat fetches don't shuffle.
            all = rows.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag
            }
            loaded = true
        }
    }

    private var header: some View {
        HStack {
            Text(l10n.t(.userV3AdvancedSearch))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.v3Text1)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.v3Text3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(Theme.v3Text3)
            TextField(l10n.t(.userV3TagSheetHint), text: $query)
                .font(.system(size: 15))
                .foregroundStyle(Theme.v3Text1)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.v3Text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.v3Surface1, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(Theme.v3Border1, lineWidth: 0.5))
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView()
            Spacer()
        } else if shown.isEmpty {
            Spacer()
            Text(emptyText)
                .font(.footnote)
                .foregroundStyle(Theme.v3Text3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    V3SectionHeading(text: l10n.t(.userV3TagSheetSectionWorks))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        Button {
                            // The filter endpoint wants the raw tag, never the
                            // translation.
                            onPick(row)
                            dismiss()
                        } label: {
                            tagRow(row, index: index, total: shown.count)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
    }

    private var emptyText: String {
        if failed { return l10n.t(.userV3TagSheetFailed) }
        return all.isEmpty ? l10n.t(.userV3TagSheetNoTag) : l10n.t(.userV3TagSheetNoMatch)
    }

    /// MD3-E segmented rows: 20pt corners at the ends, 5pt in between.
    private func tagRow(_ row: UserWorkTag, index: Int, total: Int) -> some View {
        let top: CGFloat = index == 0 ? 20 : 5
        let bottom: CGFloat = index == total - 1 ? 20 : 5
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: top
        )
        let hasTranslation = (row.translation?.isEmpty == false) && row.translation != row.tag
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hasTranslation ? (row.translation ?? "") : "#\(row.tag)")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.v3Text1)
                    .lineLimit(1)
                if hasTranslation {
                    // No translation → the raw tag moves up and the subtitle is
                    // dropped (a blank line breaks the list's rhythm).
                    Text("#\(row.tag)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3Text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text("\(row.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.v3TextAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.brand.opacity(0.10), in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.v3CardFill, in: shape)
        .overlay(shape.strokeBorder(Theme.v3CardHairline, lineWidth: 0.5))
        .padding(.bottom, 2)
        .contentShape(.rect)
    }
}
