import SwiftUI

struct ContentView: View {
    @State private var onboarding = OnboardingStore()
    @State private var auth = AuthViewModel()

    var body: some View {
        Group {
            if !onboarding.hasUserConfigured {
                LanguageOnboardingView(store: onboarding) {
                    // language chosen — flow falls through to login
                }
                .transition(.opacity)
            } else if auth.token == nil {
                LoginView(auth: auth)
                    .transition(.opacity)
            } else {
                HomeView(auth: auth)
                    .transition(.opacity)
            }
        }
        .environment(onboarding)
        .environment(\.locale, onboarding.currentLocale)
        .animation(.easeInOut(duration: 0.35), value: onboarding.hasUserConfigured)
        .animation(.easeInOut(duration: 0.35), value: auth.token != nil)
    }
}

#Preview { ContentView() }
