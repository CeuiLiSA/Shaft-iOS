#if DEBUG
import SwiftUI

/// Standalone entry gallery with production destinations for layout and routing checks.
struct DiscoverSocialPreview: View {
    @State private var locale = OnboardingStore()
    @State private var path = NavigationPath()
    @State private var auth = AuthViewModel()
    private let args = ProcessInfo.processInfo.arguments
    private func option(_ key: String) -> String? {
        args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                DiscoverSocialSection(onChat: { path.append(AppRoute.chatRoomList) }, onCommunity: { path.append(AppRoute.plaza) },
                                      accent: option("--social-accent").flatMap { UInt32($0, radix: 16) } ?? 0x686BDD)
                    .frame(maxWidth: option("--social-width").flatMap(Double.init).map { CGFloat($0) } ?? .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
            }
            .background(Theme.v3Bg)
            .registerRoutes(auth: auth)
        }
        .environment(locale)
        .environment(\.locale, Locale(identifier: option("--social-language") ?? "zh-Hans"))
        .environment(\.dynamicTypeSize, args.contains("--social-large") ? .accessibility3 : .large)
        .preferredColorScheme(args.contains("--social-dark") ? .dark : .light)
        .onAppear { locale.chosenTag = option("--social-language") ?? "zh-Hans" }
    }
}
#endif
