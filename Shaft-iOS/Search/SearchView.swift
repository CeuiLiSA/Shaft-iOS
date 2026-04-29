import SwiftUI

struct SearchView: View {
    @State private var word: String = ""
    @State private var suggestions: [AutoCompleteTag] = []
    @Environment(OnboardingStore.self) private var l10n

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l10n.t(.searchPlaceholder), text: $word)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        // navigation handled via list item — direct submit also navigates
                    }
                if !word.isEmpty {
                    Button { word = ""; suggestions = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.top, 8)

            List {
                if !word.isEmpty {
                    NavigationLink(value: AppRoute.searchResults(word: word)) {
                        Label(word, systemImage: "magnifyingglass")
                    }
                }
                Section {
                    ForEach(suggestions) { tag in
                        NavigationLink(value: AppRoute.tagResults(tag: tag.name ?? "")) {
                            VStack(alignment: .leading) {
                                Text(tag.name ?? "")
                                if let t = tag.translatedName, !t.isEmpty {
                                    Text(t).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(l10n.t(.searchTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: word) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !word.isEmpty else { suggestions = []; return }
            suggestions = (try? await api.autocompleteTags(prefix: word))?.tags ?? []
        }
    }
}

@MainActor
@Observable
final class SearchResultsViewModel {
    let word: String
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var users: [UserPreview] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(word: String) {
        self.word = word
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if illusts.isEmpty && novels.isEmpty && users.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                self.illusts = (try? await self.api.searchIllust(word: self.word))?.illusts ?? []
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                self.novels = (try? await self.api.searchNovel(word: self.word))?.novels ?? []
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                self.users = (try? await self.api.searchUser(word: self.word))?.userPreviews ?? []
            }
        }
    }
}

struct SearchResultsView: View {
    let word: String
    @State private var vm: SearchResultsViewModel
    @State private var section: Section = .illust
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case illust, novel, user }

    init(word: String) {
        self.word = word
        _vm = State(wrappedValue: SearchResultsViewModel(word: word))
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: Section.allCases.map { ($0, label(for: $0)) },
                selection: $section
            )
            TabView(selection: $section) {
                IllustWaterfallList(
                    illusts: vm.illusts, isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onTap: { _ in }
                ).tag(Section.illust)
                NovelList(novels: vm.novels).tag(Section.novel)
                UserPreviewList(items: vm.users).tag(Section.user)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("\u{201C}\(word)\u{201D}")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        case .user:   return l10n.t(.searchTabUser)
        }
    }
}

struct UserPreviewList: View {
    let items: [UserPreview]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { preview in
                    NavigationLink(value: AppRoute.userProfile(preview.user.id)) {
                        UserPreviewRow(preview: preview)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
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
