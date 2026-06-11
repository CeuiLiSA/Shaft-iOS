import SwiftUI

/// 1:1 port of upstream `fragment_language_onboarding.xml` +
/// `FragmentLanguageOnboarding`: tunnel shader behind a scrim, a greeting that
/// cycles through all supported languages every 2.2s (fade out 180ms → swap
/// text → fade in 260ms), the language rows, and a white pill continue button.
///
/// The hero (72pt) and subtitle (24pt) use FIXED frame heights with a single
/// line — different languages' glyph ascent/descent would otherwise resize the
/// greeting block and bounce the language list below on every cycle (upstream
/// fixes the TextView heights for exactly this reason).
struct LanguageOnboardingView: View {
    @Bindable var store: OnboardingStore
    var onContinue: () -> Void

    @State private var selectedTag: String = AppLocales.matchSystemOrFallback()
    @State private var cycleIndex: Int = 0
    @State private var heroOpacity: Double = 1.0
    @State private var cycleTask: Task<Void, Never>?

    private static let cycleInterval: Duration = .milliseconds(2200)

    var body: some View {
        ZStack {
            TunnelBackgroundView()
                .ignoresSafeArea()
            LoginScrimGradient()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text(AppLocales.greetings[cycleIndex].hero)
                    .font(.montserratBold(44))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 2, y: 4)
                    .opacity(heroOpacity)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                Text(AppLocales.greetings[cycleIndex].subtitle)
                    .font(.montserratSemiBold(14))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .opacity(heroOpacity * 0.75)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)

                // Rows fill the space between greeting and button; centered when
                // they fit (upstream NestedScrollView + center_vertical), and
                // scrollable on short screens.
                GeometryReader { geo in
                    ScrollView {
                        languageList
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.top, 24)

                Button {
                    store.apply(tag: selectedTag)
                    onContinue()
                } label: {
                    Text(AppLocales.continueLabel(for: selectedTag))
                        .font(.montserratSemiBold(20))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(.white, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 30)
                .padding(.bottom, 48)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            cycleIndex = AppLocales.greetings.firstIndex { $0.tag == selectedTag } ?? 0
            startCycle()
        }
        .onDisappear { cycleTask?.cancel() }
    }

    private var languageList: some View {
        VStack(spacing: 0) {
            ForEach(Array(AppLocales.supportedTags.enumerated()), id: \.element) { idx, tag in
                Button { selectTag(tag) } label: {
                    HStack {
                        Text(AppLocales.displayName(tag))
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 5, y: 1)
                        Spacer()
                        Text("✓")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 5, y: 1)
                            .opacity(tag == selectedTag ? 1 : 0)
                            .animation(.linear(duration: 0.16), value: selectedTag)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 56)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if idx < AppLocales.supportedTags.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.2))
                        .frame(height: 0.5)
                }
            }
        }
    }

    private func selectTag(_ tag: String) {
        guard tag != selectedTag else { return }
        selectedTag = tag
        // Upstream jumps the greeting to the picked language (same fade).
        if let idx = AppLocales.greetings.firstIndex(where: { $0.tag == tag }) {
            fadeGreeting(to: idx)
        }
    }

    /// Upstream `cycleRunnable`: re-fires every 2.2s for as long as the page is
    /// on screen.
    private func startCycle() {
        cycleTask?.cancel()
        cycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.cycleInterval)
                guard !Task.isCancelled else { break }
                fadeGreeting(to: (cycleIndex + 1) % AppLocales.greetings.count)
            }
        }
    }

    /// Upstream `fadeGreetingTo`: 180ms fade-out, swap the text while
    /// invisible, then 260ms fade-in (subtitle settles at 0.75 alpha via the
    /// `heroOpacity * 0.75` binding).
    private func fadeGreeting(to index: Int) {
        Task { @MainActor in
            withAnimation(.linear(duration: 0.18)) { heroOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(180))
            cycleIndex = index
            withAnimation(.linear(duration: 0.26)) { heroOpacity = 1 }
        }
    }
}
