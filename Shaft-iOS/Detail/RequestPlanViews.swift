import SwiftUI

// MARK: - Models (/v1/user/request-plans)

/// Single page, no `next_url` — upstream maps it with a plain feed source.
struct UserRequestPlansResponse: Codable, Sendable {
    let requestPlans: [RequestPlan]?
    let user: PixivUser?

    enum CodingKeys: String, CodingKey {
        case requestPlans = "request_plans"
        case user
    }
}

/// One commission plan. `standardPrice` is in yen (40000 = ¥40,000);
/// `aiType` follows pixiv's usual 1 = human, 2 = AI.
struct RequestPlan: Codable, Sendable, Hashable, Identifiable {
    let id: Int64
    let standardPrice: Int
    let acceptFlags: RequestPlanAcceptFlags?
    let aiType: Int?
    let title: RequestPlanText?
    let description: RequestPlanText?
    let imageUrls: RequestPlanImageUrls?

    enum CodingKeys: String, CodingKey {
        case id, title, description
        case standardPrice = "standard_price"
        case acceptFlags = "accept_flags"
        case aiType = "ai_type"
        case imageUrls = "image_urls"
    }

    /// Every field defaults, like the Gson model upstream: one plan missing a
    /// scalar must not fail the whole tab's decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        standardPrice = try c.decodeIfPresent(Int.self, forKey: .standardPrice) ?? 0
        acceptFlags = try c.decodeIfPresent(RequestPlanAcceptFlags.self, forKey: .acceptFlags)
        aiType = try c.decodeIfPresent(Int.self, forKey: .aiType)
        title = try c.decodeIfPresent(RequestPlanText.self, forKey: .title)
        description = try c.decodeIfPresent(RequestPlanText.self, forKey: .description)
        imageUrls = try c.decodeIfPresent(RequestPlanImageUrls.self, forKey: .imageUrls)
    }
}

struct RequestPlanAcceptFlags: Codable, Sendable, Hashable {
    let adult: Bool?
    let anonymous: Bool?
    let illust: Bool?
    let ugoira: Bool?
    let manga: Bool?
    let novel: Bool?
}

/// The server splits title / description into source text plus a translation.
struct RequestPlanText: Codable, Sendable, Hashable {
    let original: String?
    let originalLang: String?
    let translation: String?

    enum CodingKeys: String, CodingKey {
        case original, translation
        case originalLang = "original_lang"
    }

    /// Translation first, source as the fallback.
    var display: String {
        if let t = translation, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        return original?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

struct RequestPlanImageUrls: Codable, Sendable, Hashable {
    let cover: String?
    let card: String?

    /// Cards use the 800×400 `card`, falling back to `cover`.
    var cardOrCover: String? {
        if let c = card, !c.isEmpty { return c }
        return cover
    }
}

// MARK: - Feed

@MainActor
@Observable
final class UserRequestPlanFeed {
    let userId: Int64
    var plans: [RequestPlan] = []
    var author: PixivUser?
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        guard !loaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await api.userRequestPlans(userId)
            plans = r.requestPlans ?? []
            author = r.user
            loaded = true
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - 约稿中 tab (RequestPlanFeedFragment)

struct UserV3RequestTab: View {
    @Bindable var feed: UserRequestPlanFeed
    @State private var picked: RequestPlan?

    var body: some View {
        VStack(spacing: 14) {
            if feed.plans.isEmpty {
                V3TabPlaceholder(
                    isLoading: feed.isLoading, error: feed.errorMessage, style: .rows
                ) { Task { await feed.loadIfNeeded() } }
            } else {
                ForEach(feed.plans) { plan in
                    Button { picked = plan } label: {
                        RequestPlanCard(plan: plan)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .task { await feed.loadIfNeeded() }
        .navigationDestination(item: $picked) { plan in
            RequestPlanDetailView(plan: plan, author: feed.author)
        }
    }
}

/// MD3-Expressive cover card (`cell_request_plan.xml`): full-bleed cover, title,
/// price pill, description, accepted-type chips.
struct RequestPlanCard: View {
    let plan: RequestPlan
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover = plan.imageUrls?.cardOrCover, let url = URL(string: cover) {
                PixivAsyncImage(url: url)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(plan.title?.display ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.v3Text1)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if plan.acceptFlags?.adult == true {
                        Text(l10n.t(.userV3RequestBadgeAdult))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: 0xE0246A), in: .capsule)
                    }
                }
                Text(l10n.t(.userV3RequestPriceFmt, plan.standardPrice.formatted()))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.v3FloatingPillContent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.brand, in: .capsule)

                let desc = plan.description?.display ?? ""
                if !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3TextSecondary)
                        .lineLimit(3)
                }
                RequestPlanChips(plan: plan)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // `V3Palette.settingsCardBg`: tinted fill + 12% brand hairline, r28.
        .background(Theme.v3CardFill, in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28)
            .strokeBorder(Theme.v3CardHairline, lineWidth: 1))
        .clipShape(.rect(cornerRadius: 28))
        .contentShape(.rect)
    }
}

/// Tonal chips = what the artist will draw; outlined = extra conditions.
private struct RequestPlanChips: View {
    let plan: RequestPlan
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        FlowLayout(spacing: 6) {
            if plan.acceptFlags?.illust == true { chip(l10n.t(.userV3RequestFlagIllust), tonal: true) }
            if plan.acceptFlags?.manga == true { chip(l10n.t(.userV3RequestFlagManga), tonal: true) }
            if plan.acceptFlags?.ugoira == true { chip(l10n.t(.userV3RequestFlagUgoira), tonal: true) }
            if plan.acceptFlags?.novel == true { chip(l10n.t(.userV3RequestFlagNovel), tonal: true) }
            if plan.acceptFlags?.anonymous == true {
                chip(l10n.t(.userV3RequestFlagAnonymous), tonal: false)
            }
            if plan.aiType == 2 { chip(l10n.t(.userV3RequestFlagAI), tonal: false) }
        }
    }

    private func chip(_ text: String, tonal: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.v3TagText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tonal ? AnyShapeStyle(Theme.v3TagChipFill) : AnyShapeStyle(Color.clear),
                        in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.v3TagChipBorder, lineWidth: 1))
    }
}

// MARK: - Plan detail (RequestPlanDetailFragment)

/// Everything about a plan in-app; actually commissioning still goes to the web
/// (pixiv has no app-api ordering endpoint), same as upstream's CTA.
struct RequestPlanDetailView: View {
    let plan: RequestPlan
    let author: PixivUser?

    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    private var planURL: URL? {
        URL(string: "https://www.pixiv.net/request/plans/\(plan.id)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let cover = plan.imageUrls?.cover ?? plan.imageUrls?.card,
                   let url = URL(string: cover) {
                    PixivAsyncImage(url: url)
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(.rect(cornerRadius: 20))
                }

                if let author { authorRow(author) }

                card(l10n.t(.userV3RequestPriceLabel)) {
                    Text(l10n.t(.userV3RequestPriceFmt, plan.standardPrice.formatted()))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.v3Text1)
                }

                card(l10n.t(.userV3RequestFlagsLabel)) {
                    RequestPlanChips(plan: plan)
                }

                if let title = plan.title, !title.display.isEmpty {
                    card(l10n.t(.userV3RequestTitleLabel)) {
                        textWithOriginal(title)
                    }
                }

                if let desc = plan.description, !desc.display.isEmpty {
                    card(l10n.t(.userV3RequestDescLabel)) {
                        textWithOriginal(desc)
                    }
                }

                card(l10n.t(.userV3RequestMetaLabel)) {
                    VStack(alignment: .leading, spacing: 8) {
                        metaRow(l10n.t(.userV3RequestMetaId), "\(plan.id)")
                        metaRow(l10n.t(.userV3RequestMetaAI), aiLabel)
                    }
                }

                Button {
                    if let planURL { openURL(planURL) }
                } label: {
                    Text(l10n.t(.userV3RequestGoCommission))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.brand, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(16)
        }
        .background(Theme.v3Bg)
        .navigationTitle(l10n.t(.userV3TabRequest))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aiLabel: String {
        switch plan.aiType {
        case 1: return l10n.t(.userV3RequestAINone)
        case 2: return l10n.t(.userV3RequestAIGenerated)
        default: return l10n.t(.userV3RequestAIUnknown)
        }
    }

    private func authorRow(_ user: PixivUser) -> some View {
        NavigationLink(value: AppRoute.userProfile(user.id)) {
            HStack(spacing: 12) {
                PixivAsyncImage(url: user.profileImageUrls?.medium.flatMap(URL.init(string:)))
                    .frame(width: 44, height: 44)
                    .clipShape(.circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.v3Text1)
                    Text("@\(user.account ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3Text3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.v3Text3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.v3CardFill, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.v3CardHairline, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func textWithOriginal(_ text: RequestPlanText) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.display)
                .font(.system(size: 14))
                .foregroundStyle(Theme.v3Text1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The source text is kept alongside the translation, labelled with
            // its language when the server reports one.
            if let original = text.original, !original.isEmpty, original != text.display {
                DisclosureGroup(
                    text.originalLang.map { l10n.t(.userV3RequestOrigFmt, $0) }
                        ?? l10n.t(.userV3RequestOrigFmt, "")
                ) {
                    Text(original)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, weight: .semibold))
                .tint(Theme.v3Text3)
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.v3Text3)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.v3Text1)
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            V3SectionHeading(text: label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.v3CardFill, in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28)
            .strokeBorder(Theme.v3CardHairline, lineWidth: 1))
    }
}
