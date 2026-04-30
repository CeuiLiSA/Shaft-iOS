import SwiftUI

struct AboutView: View {
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shaft-iOS").font(.title2.bold())
                    Text("Pixiv client for iOS, mirroring Pixiv-Shaft (classic).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("v0.1 · OAuth 2.0 with PKCE · No third-party tracking")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Link(destination: URL(string: "https://github.com/SoxiaLiSA/Shaft-iOS")!) {
                    Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/SoxiaLiSA/Pixiv-Shaft")!) {
                    Label("Pixiv-Shaft (Android)", systemImage: "link")
                }
            }
        }
        .navigationTitle(l10n.t(.aboutTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadsView: View {
    @Environment(OnboardingStore.self) private var l10n
    var body: some View {
        PlaceholderView(title: l10n.t(.downloadsTitle),
                        systemImage: "arrow.down.circle",
                        subtitle: l10n.t(.nothingHere))
            .navigationTitle(l10n.t(.downloadsTitle))
            .navigationBarTitleDisplayMode(.inline)
    }
}

