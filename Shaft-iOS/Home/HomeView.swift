import SwiftUI

struct HomeView: View {
    @Bindable var auth: AuthViewModel
    @State private var selection: HomeTab = .recommend
    @State private var showProfile = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(HomeTab.allCases) { tab in
                NavigationStack {
                    EmptyTabView(tab: tab)
                        .navigationTitle(tab.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showProfile = true
                                } label: {
                                    Image(systemName: "person.crop.circle")
                                }
                                .accessibilityLabel("Account")
                            }
                        }
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .tag(tab)
            }
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                LoggedInView(auth: auth)
                    .navigationTitle("Account")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showProfile = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

enum HomeTab: String, CaseIterable, Identifiable {
    case recommend, discover, whatsNew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommend: return "Recommend"
        case .discover:  return "Discover"
        case .whatsNew:  return "What's New"
        }
    }

    var systemImage: String {
        switch self {
        case .recommend: return "sparkles"
        case .discover:  return "safari"
        case .whatsNew:  return "bell"
        }
    }
}

struct EmptyTabView: View {
    let tab: HomeTab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.title3.weight(.semibold))
            Text("Nothing here yet")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
