import SwiftUI

struct LanguageOnboardingView: View {
    @Bindable var store: OnboardingStore
    var onContinue: () -> Void

    @State private var selectedTag: String = AppLocales.matchSystemOrFallback()
    @State private var cycleIndex: Int = 0
    @State private var heroOpacity: Double = 1.0

    private let cycleInterval: TimeInterval = 2.2
    private let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            TunnelBackgroundView()
                .ignoresSafeArea()
            LoginScrimGradient()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 8) {
                    Text(AppLocales.greetings[cycleIndex].hero)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                        .opacity(heroOpacity)
                    Text(AppLocales.greetings[cycleIndex].subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.75))
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        .opacity(heroOpacity * 0.85)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

                Spacer(minLength: 32)

                languageList
                    .padding(.horizontal, 20)

                Spacer(minLength: 24)

                Button {
                    store.apply(tag: selectedTag)
                    onContinue()
                } label: {
                    Text(AppLocales.continueLabel(for: selectedTag))
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.black)
                        .background(.white, in: .rect(cornerRadius: 14))
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            cycleIndex = AppLocales.greetings.firstIndex { $0.tag == selectedTag } ?? 0
        }
        .onReceive(timer) { _ in
            advanceCycle()
        }
    }

    private var languageList: some View {
        VStack(spacing: 0) {
            ForEach(Array(AppLocales.supportedTags.enumerated()), id: \.element) { idx, tag in
                Button { selectTag(tag) } label: {
                    HStack {
                        Text(AppLocales.displayName(tag))
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
                            .opacity(tag == selectedTag ? 1 : 0)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 56)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if idx < AppLocales.supportedTags.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(height: 0.5)
                }
            }
        }
    }

    private func selectTag(_ tag: String) {
        guard tag != selectedTag else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            selectedTag = tag
        }
        cycleIndex = AppLocales.greetings.firstIndex { $0.tag == tag } ?? cycleIndex
        fadeHero()
    }

    private func advanceCycle() {
        cycleIndex = (cycleIndex + 1) % AppLocales.greetings.count
        fadeHero()
    }

    private func fadeHero() {
        withAnimation(.easeOut(duration: 0.18)) { heroOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeIn(duration: 0.26)) { heroOpacity = 1 }
        }
    }
}
