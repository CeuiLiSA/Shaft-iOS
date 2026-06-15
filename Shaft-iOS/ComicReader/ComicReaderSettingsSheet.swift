import SwiftUI

// Reader settings bottom sheet (sheet_comic_reader_settings parity): segmented
// rows for reading mode / direction / fit / flip animation, brightness switch +
// conditional slider, warm-filter and preload sliders, and the interaction
// toggle group. Volume-key flip is omitted (iOS can't intercept volume keys).
struct ComicReaderSettingsSheet: View {
    @Bindable var settings: ComicReaderSettings
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    segmented(l10n.t(.crModeLabel), [
                        (l10n.t(.crModePaged), ComicReaderSettings.ReadingMode.paged),
                        (l10n.t(.crModeWebtoon), .webtoon),
                    ], $settings.readingMode)

                    segmented(l10n.t(.crDirectionLabel), [
                        (l10n.t(.crDirLtr), ComicReaderSettings.PageDirection.ltr),
                        (l10n.t(.crDirRtl), .rtl),
                    ], $settings.pageDirection)

                    segmented(l10n.t(.crFitLabel), [
                        (l10n.t(.crFitWidth), ComicReaderSettings.FitMode.fitWidth),
                        (l10n.t(.crFitScreen), .fitScreen),
                        (l10n.t(.crFitOriginal), .fitOriginal),
                    ], $settings.fitMode)

                    segmented(l10n.t(.crAnimLabel), [
                        (l10n.t(.crAnimSlide), ComicReaderSettings.FlipAnim.slide),
                        (l10n.t(.crAnimCover), .cover),
                        (l10n.t(.crAnimDepth), .depth),
                        (l10n.t(.crAnimFlipbook), .flipBook),
                    ], $settings.flipAnim)

                    switchRow(l10n.t(.crBrightnessSystem), $settings.useSystemBrightness)
                    if !settings.useSystemBrightness {
                        floatSlider(l10n.t(.crBrightnessLabel), $settings.customBrightness, 0.01...1)
                    }
                    floatSlider(l10n.t(.crWarmLabel), $settings.warmFilterStrength, 0...0.6)
                    intSlider(l10n.t(.crPreloadLabel), $settings.preloadAhead, 0...8)

                    switchRow(l10n.t(.crKeepScreenOn), $settings.keepScreenOn)
                    switchRow(l10n.t(.crImmersive), $settings.immersive)
                    switchRow(l10n.t(.crShowPageNumber), $settings.showPageNumber)
                    switchRow(l10n.t(.crLoadOriginal), $settings.loadOriginal)
                    switchRow(l10n.t(.crTapReversed), $settings.tapZoneReversed)
                }
                .padding(20)
            }
            .navigationTitle(l10n.t(.crSettings))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t(.actionDone)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Rows

    private func segmented<T: Hashable>(_ title: String, _ options: [(String, T)], _ selection: Binding<T>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.v3Text2)
            HStack(spacing: 6) {
                ForEach(options, id: \.1) { label, value in
                    Button {
                        selection.wrappedValue = value
                    } label: {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(selection.wrappedValue == value ? Color.white : Theme.v3Text1)
                            .background(
                                selection.wrappedValue == value
                                    ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.v3Surface),
                                in: .rect(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func switchRow(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.v3Text1)
        }
        .tint(Theme.brand)
    }

    private func floatSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.v3Text1)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 13)).foregroundStyle(Theme.v3Text3)
            }
            Slider(value: value, in: range).tint(Theme.brand)
        }
    }

    private func intSlider(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.v3Text1)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(size: 13)).foregroundStyle(Theme.v3Text3)
            }
            Slider(
                value: Binding(get: { Double(value.wrappedValue) },
                               set: { value.wrappedValue = Int($0.rounded()) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(Theme.brand)
        }
    }
}
