import SwiftUI

// MARK: - 资料 tab (UserV3InfoFragment)

/// Profile-details card → social-links card → bio → collapsible workspace card
/// → mute strip (others only), in that order, on a 20pt gutter.
struct V3ProfileInfoPage: View {
    @Bindable var vm: UserProfileViewModel
    let isSelf: Bool

    @State private var workspaceExpanded = true
    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.user != nil { profileCard }

            if !socialRows.isEmpty {
                socialCard
                    .padding(.top, 16)
            }

            if let bio = bioAttributed {
                Text(bio)
                    .font(.system(size: 14))
                    // lineSpacingMultiplier 1.6 on a 14sp body.
                    .lineSpacing(8)
                    .foregroundStyle(Theme.v3Text1.opacity(0.78))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
            }

            if !workspaceItems.isEmpty {
                workspaceCard
                    .padding(.top, 16)
            }

            if !isSelf {
                muteStrip
                    .padding(.top, 20)
            }

            // Upstream's trailing 60dp spacer under the bottom padding.
            Color.clear.frame(height: 60)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 32)
    }

    // ── Profile details card ────────────────────────────────────────

    struct ChipData: Identifiable {
        let label: String
        let value: String
        /// "Pixiv URL" takes a whole row (upstream checks the label).
        var isWide = false
        var isPremium = false
        var url: URL?
        var id: String { label }
    }

    private var profileChips: [ChipData] {
        guard let user = vm.user else { return [] }
        let p = vm.profile
        // Labels are hardcoded English upstream — kept verbatim rather than
        // localized, so both builds read the same.
        // `UserV3InfoFragment.setupProfileCard` builds this card from string
        // literals, so the labels and the gender/premium values stay English in
        // every app language. Routing them through `l10n` (as this used to)
        // made the card the one localized surface Android never localizes.
        var chips: [ChipData] = [
            ChipData(label: "User ID", value: String(user.id)),
            ChipData(label: "Account", value: user.account ?? ""),
        ]
        if let gender = p?.gender, !gender.isEmpty {
            let text: String
            switch gender {
            case "male": text = "Male"
            case "female": text = "Female"
            default: text = gender
            }
            chips.append(ChipData(label: "Gender", value: text))
        }
        if let region = p?.region, !region.isEmpty {
            chips.append(ChipData(label: "Region", value: region))
        }
        if let birthday = p?.birthDay, !birthday.isEmpty {
            chips.append(ChipData(label: "Birthday", value: birthday))
        }
        if let job = p?.job, !job.isEmpty {
            chips.append(ChipData(label: "Job", value: job))
        }
        let premium = user.isPremium == true || p?.isPremium == true
        chips.append(ChipData(
            label: "Premium",
            value: premium ? "\u{2605} Premium User" : "Standard",
            isPremium: premium
        ))
        chips.append(ChipData(
            label: "Pixiv URL",
            value: "https://www.pixiv.net/users/\(user.id)",
            isWide: true,
            url: URL(string: "https://www.pixiv.net/users/\(user.id)")
        ))
        return chips
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            V3SectionHeading(text: l10n.t(.v3LabelProfileDetails))
            chipGrid(profileChips)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .v3GlassXL()
    }

    /// Two-up chip rows. A wide chip — or a trailing odd one — takes the whole
    /// row; otherwise the pair is taken as-is, *including* when the second one
    /// is the wide "Pixiv URL" (upstream only tests the first chip of a row).
    @ViewBuilder
    private func chipGrid(_ chips: [ChipData]) -> some View {
        let rows = packChips(chips)
        // Every row carries `bottomMargin = 10dp`, the last one included.
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { chip in
                        V3ProfileChip(
                            label: chip.label, value: chip.value,
                            isPremium: chip.isPremium, url: chip.url
                        )
                    }
                }
            }
        }
        .padding(.bottom, 10)   // the last row keeps its bottomMargin too
    }

    private func packChips(_ chips: [ChipData]) -> [[ChipData]] {
        var rows: [[ChipData]] = []
        var i = 0
        while i < chips.count {
            if chips[i].isWide || i + 1 >= chips.count {
                rows.append([chips[i]])
                i += 1
            } else {
                rows.append([chips[i], chips[i + 1]])
                i += 2
            }
        }
        return rows
    }

    // ── Social links card ───────────────────────────────────────────

    struct SocialRow: Identifiable {
        let platform: String
        let label: String
        let url: String
        var id: String { "\(platform.lowercased()):\(url)" }
    }

    /// App-API links first (twitter / webpage / pawoo), then whatever the web
    /// supplement adds, de-duped on `platform:url` like `addSocialChip`.
    private var socialRows: [SocialRow] {
        var rows: [SocialRow] = []
        var seen = Set<String>()
        func add(_ platform: String, _ label: String, _ url: String?) {
            guard let url, !url.isEmpty else { return }
            let row = SocialRow(platform: platform, label: label, url: url)
            guard seen.insert(row.id).inserted else { return }
            rows.append(row)
        }
        if let p = vm.profile {
            let twitterLabel = (p.twitterAccount?.isEmpty == false)
                ? "@\(p.twitterAccount!)" : "X (Twitter)"
            add("twitter", twitterLabel, p.twitterUrl)
            add("webpage", "Website", p.webpage)
            add("pawoo", "Pawoo", p.pawooUrl)
        }
        if let web = vm.webDetail {
            for (platform, url) in web.social.sorted(by: { $0.key < $1.key }) {
                add(platform, prettySocialLabel(platform), url)
            }
            add("webpage", "Website", web.webpage)
        }
        return rows
    }

    private func prettySocialLabel(_ platform: String) -> String {
        switch platform.lowercased() {
        case "twitter", "x": return "X (Twitter)"
        case "youtube": return "YouTube"
        case "tiktok": return "TikTok"
        case "linkedin": return "LinkedIn"
        case "github": return "GitHub"
        case "webpage": return "Website"
        default: return platform.prefix(1).uppercased() + platform.dropFirst()
        }
    }

    /// Badge tints are the upstream `socialStyle` values verbatim. The glyphs
    /// are SF Symbols: iOS ships no brand logos, and upstream's `ic_v3_social_*`
    /// vectors are the platforms' own marks.
    private func socialStyle(_ platform: String) -> (icon: String, badge: Color) {
        switch platform.lowercased() {
        case "instagram": return ("camera", Color(hex: 0xFFE7FC))
        case "facebook": return ("person.2", Color(hex: 0xDBF2FE))
        case "twitter", "x": return ("at", Color(hex: 0xDFDFDF))
        case "youtube": return ("play.rectangle", Color(hex: 0xFFD6CD))
        case "tiktok": return ("music.note", Color(hex: 0xDFDFDF))
        case "linkedin": return ("briefcase", Color(hex: 0xE0EFFF))
        case "spotify": return ("music.note.list", Color(hex: 0xD5EDC2))
        default: return ("link", Color(hex: 0xE8DCCD))
        }
    }

    private var socialCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            V3SectionHeading(text: l10n.t(.v3LabelSocial))
                .padding(.bottom, 6)
            ForEach(Array(socialRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.v3Border2)
                        .frame(height: 0.5)
                }
                socialRowView(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .v3GlassXL()
    }

    private func socialRowView(_ row: SocialRow) -> some View {
        let style = socialStyle(row.platform)
        return Button {
            if let url = URL(string: row.url) { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: style.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1A1A2E))
                    .frame(width: 36, height: 36)
                    .background(style.badge, in: .rect(cornerRadius: 10))
                Text(row.label)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.v3Text1)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.v3Text3)
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // ── Bio ─────────────────────────────────────────────────────────

    /// The web `commentHtml` carries richer markup (`<a>` etc.) than the
    /// app-api `comment`, so it wins when present — same override upstream.
    private var bioAttributed: AttributedString? {
        if let html = vm.webDetail?.commentHtml, !html.isEmpty {
            return V3BioHTML.attributed(html)
        }
        if let comment = vm.user?.comment, !comment.isEmpty {
            return V3BioHTML.attributed(comment)
        }
        return nil
    }

    // ── Workspace card ──────────────────────────────────────────────

    private var workspaceItems: [ChipData] {
        guard let w = vm.workspace else { return [] }
        // Upstream hardcodes these English labels; keep them for parity.
        let pairs: [(String, String?)] = [
            ("PC", w.pc), ("Monitor", w.monitor), ("Tool", w.tool),
            ("Tablet", w.tablet), ("Scanner", w.scanner), ("Mouse", w.mouse),
            ("Printer", w.printer), ("Desktop", w.desktop), ("Music", w.music),
            ("Desk", w.desk), ("Chair", w.chair), ("Comment", w.comment),
        ]
        return pairs.compactMap { label, value in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return ChipData(label: label, value: value)
        }
    }

    private var workspaceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { workspaceExpanded.toggle() }
            } label: {
                HStack {
                    V3SectionHeading(text: l10n.t(.v3LabelWorkspace))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.v3Text3)
                        .rotationEffect(.degrees(workspaceExpanded ? 0 : -90))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if workspaceExpanded {
                chipGrid(workspaceItems)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .v3GlassXL()
    }

    // ── Mute strip ──────────────────────────────────────────────────

    private var muteStrip: some View {
        HStack {
            Text(l10n.t(.v3BlockUserWorks))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.v3Text2)
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { mute.isUserMuted(vm.userId) },
                set: { _ in mute.toggleUser(vm.userId) }
            ))
            .labelsHidden()
        }
        .padding(14)
        // bg_v3_mute_strip: #26FF2D78 fill, #40FF2D78 hairline, r20.
        .background(Color(hex: 0xFF2D78).opacity(38 / 255), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color(hex: 0xFF2D78).opacity(64 / 255), lineWidth: 0.5)
        )
    }
}

// MARK: - Profile detail chip (item_v3_profile_chip)

private struct V3ProfileChip: View {
    let label: String
    let value: String
    var isPremium = false
    var url: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.7)
                .foregroundStyle(Theme.v3Text3.opacity(0.7))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // bg_v3_chip: v3_surface_1 fill, 0.5dp v3_border_1 hairline, r14.
        .background(Theme.v3Surface1, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.v3Border1, lineWidth: 0.5)
        )
        .contentShape(.rect)
        .onTapGesture {
            // Tap-to-open rather than an inline link: upstream dropped
            // LinkMovementMethod because dragging a link stole the pager's
            // horizontal gesture (issue #917).
            if let url { openURL(url) }
        }
    }

    /// `item_v3_profile_chip.xml` puts `alpha="0.82"` on the whole TextView,
    /// so the gold premium value and the link-colored URL are dimmed too.
    private var valueColor: Color {
        if isPremium { return Theme.v3Gold.opacity(0.82) }
        if url != nil { return Theme.brand.opacity(0.82) }
        return Theme.v3Text1.opacity(0.82)
    }
}

// MARK: - Bio HTML

/// `HtmlCompat.fromHtml(FROM_HTML_MODE_COMPACT)` + `LinkMovementMethod` +
/// `autoLink="all"`: keeps `<a>` targets tappable, turns bare URLs into links,
/// and renders everything else as plain text with the breaks preserved.
enum V3BioHTML {
    private static let anchor = try? NSRegularExpression(
        pattern: "<a[^>]*href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ html: String) -> AttributedString? {
        var source = html
        for br in ["<br />", "<br/>", "<br>", "</p>", "</P>"] {
            source = source.replacingOccurrences(of: br, with: "\n")
        }

        var out = AttributedString()
        var cursor = source.startIndex
        if let anchor {
            let ns = source as NSString
            for m in anchor.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                guard let full = Range(m.range, in: source),
                      let hrefRange = Range(m.range(at: 1), in: source),
                      let textRange = Range(m.range(at: 2), in: source)
                else { continue }
                out.append(plainRun(String(source[cursor..<full.lowerBound])))
                var link = AttributedString(strip(String(source[textRange])))
                link.foregroundColor = Color(hex: 0x3D8BFD)
                link.link = URL(string: decode(String(source[hrefRange])))
                out.append(link)
                cursor = full.upperBound
            }
        }
        out.append(plainRun(String(source[cursor...])))

        // Trim the surrounding whitespace the markup leaves behind.
        while let first = out.characters.first, first.isWhitespace {
            out.removeSubrange(out.startIndex..<out.index(afterCharacter: out.startIndex))
        }
        while let last = out.characters.last, last.isWhitespace {
            out.removeSubrange(out.index(beforeCharacter: out.endIndex)..<out.endIndex)
        }
        return out.characters.isEmpty ? nil : out
    }

    /// Non-anchor text: strip tags, decode entities, then linkify bare URLs
    /// (the TextView's `autoLink="all"`).
    private static func plainRun(_ raw: String) -> AttributedString {
        let text = strip(raw)
        var run = AttributedString(text)
        guard let detector, !text.isEmpty else { return run }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let r = Range(m.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: run),
                  let upper = AttributedString.Index(r.upperBound, within: run)
            else { continue }
            run[lower..<upper].link = url
            run[lower..<upper].foregroundColor = Color(hex: 0x3D8BFD)
        }
        return run
    }

    private static func strip(_ s: String) -> String {
        decode(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }

    private static func decode(_ s: String) -> String {
        var out = s
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

extension View {
    /// `v3_glass_surface_xl`: `v3_surface_1` fill, 1dp `v3_border_2` hairline,
    /// 28dp corners.
    func v3GlassXL() -> some View {
        self
            .background(Theme.v3Surface1, in: .rect(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28)
                .strokeBorder(Theme.v3Border2, lineWidth: 1))
    }
}
