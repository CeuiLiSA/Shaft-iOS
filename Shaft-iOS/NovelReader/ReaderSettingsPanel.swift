import SwiftUI

// 1:1 port of upstream ReaderSettingsPanel (fragment_reader_settings):
// five sections — 排版 (font size/line/paragraph spacing/margins/indent/
// letter spacing/bold/font/weight), 主题 (swatches/follow dark/brightness/
// warm filter), 翻页 (direction/flip animation/tap zones/auto page), 屏幕
// (immersive/keep on/touch lock/eye break), 图片 (placement/scale/preload).
// Android-only rows (volume keys, orientation lock) are not ported.

struct ReaderSettingsPanel: View {
    @Environment(OnboardingStore.self) private var l10n
    @Bindable var settings: NovelReaderSettings
    @Environment(\.colorScheme) private var colorScheme
    /// The preset whose text colour the open picker edits — captured when the
    /// picker opens, so a system day/night flip mid-pick can't write the other
    /// theme (#1142).
    @State private var textColorTarget: ReaderTheme?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    typographySection
                    themeSection
                    flipSection
                    screenSection
                    imageSection
                }
                .padding(16)
            }
            .navigationTitle(l10n.t(.nrSettingsTitle))
            .sheet(item: $textColorTarget) { theme in
                HSVColorPickerSheet(
                    title: l10n.t(.nrTextColor),
                    initialRGB: theme.textColor.rgb24,
                    textBackground: theme.backgroundColor
                ) { rgb in
                    settings.setTextColor(presetId: theme.id, rgb: rgb)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 排版

    private var typographySection: some View {
        section(l10n.t(.nrSectionTypography)) {
            intSlider(l10n.t(.nrFontSize), value: $settings.fontSizeSp, range: 12...36, suffix: "sp")
            floatSlider(l10n.t(.nrLineSpacing), value: $settings.lineSpacing, range: 1.0...2.8)
            floatSlider(l10n.t(.nrParagraphSpacing), value: $settings.paragraphSpacingLines, range: 0...2.5)
            intSlider(l10n.t(.nrHMargin), value: $settings.horizontalMarginDp, range: 0...64, suffix: "pt")
            intSlider(l10n.t(.nrVMargin), value: $settings.verticalMarginDp, range: 0...96, suffix: "pt")
            segmented(l10n.t(.nrFirstIndent), selection: $settings.firstLineIndent, options: [0, 1, 2, 3, 4]) {
                $0 == 0 ? l10n.t(.nrIndentNone) : String(format: l10n.t(.nrIndentFmt), $0)
            }
            floatSlider(l10n.t(.nrLetterSpacing), value: $settings.letterSpacing, range: -0.05...0.25)
            Toggle(l10n.t(.nrBold), isOn: $settings.boldText)
            fontPicker
            intSlider(l10n.t(.nrFontWeight), value: $settings.fontWeight, range: 100...900, suffix: "")
        }
    }

    private var fontPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PresetFont.builtIn) { font in
                    let selected = settings.fontId == font.id
                    Button {
                        settings.fontId = font.id
                    } label: {
                        Text(l10n.t(font.nameKey))
                            .font(Font(font.font(size: 13, weight: 400, bold: false)))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(selected ? Color.accentColor : Theme.v3Surface, in: .rect(cornerRadius: 8))
                            .foregroundStyle(selected ? .white : Theme.v3Text1)
                    }
                }
            }
        }
    }

    // MARK: 主题

    private var themeSection: some View {
        section(l10n.t(.nrSectionTheme)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    // 选中环跟着**生效**主题走（跟随开启时它可能不是 themeId，#1132）。
                    let effectiveId = settings.effectiveTheme(systemIsDark: colorScheme == .dark).id
                    ForEach(ReaderTheme.presets) { theme in
                        let selected = effectiveId == theme.id
                        Button {
                            settings.onThemePicked(theme.id, systemIsDark: colorScheme == .dark)
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(Color(theme.backgroundColor))
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Text("文")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(Color(theme.textColor))
                                    )
                                    .overlay(
                                        Circle().strokeBorder(
                                            selected ? Color.accentColor : Color.black.opacity(0.13),
                                            lineWidth: selected ? 2 : 1
                                        )
                                    )
                                Text(l10n.t(theme.nameKey))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.v3Text2)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            textColorRows
            Toggle(l10n.t(.nrFollowDark), isOn: $settings.followSystemDarkMode)
            Toggle(l10n.t(.nrSystemBrightness), isOn: $settings.useSystemBrightness)
            if !settings.useSystemBrightness {
                floatSlider(l10n.t(.nrCustomBrightness), value: $settings.customBrightness, range: 0.01...1.0)
            }
            floatSlider(l10n.t(.nrWarmFilter), value: $settings.warmFilterStrength, range: 0...0.6)
        }
    }

    /// 「文字颜色」(#1142)：配色下方，按当前生效配色记住正文与章节标题的字色；
    /// 只有该配色存过自定义字色时才露出「恢复默认字色」。
    @ViewBuilder
    private var textColorRows: some View {
        let theme = settings.effectiveTheme(systemIsDark: colorScheme == .dark)
        Button {
            textColorTarget = theme
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t(.nrTextColor))
                    .font(.montserratMedium(15))
                    .foregroundStyle(Theme.v3Text1)
                Text(HSV.hex(theme.textColor.rgb24))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.v3Text2)
                Text(l10n.t(.nrTextColorHint))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.v3Text2)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        if settings.customTextColor(presetId: theme.id) != nil {
            Button {
                settings.setTextColor(presetId: theme.id, rgb: nil)
            } label: {
                Text(l10n.t(.nrTextColorReset))
                    .font(.montserratMedium(14))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 翻页

    private var flipSection: some View {
        section(l10n.t(.nrSectionFlip)) {
            segmented(l10n.t(.nrReadingDirection), selection: $settings.readingDirection,
                      options: ReadingDirection.allCases) {
                l10n.t($0 == .horizontal ? .nrDirectionHorizontal : .nrDirectionVertical)
            }
            if settings.readingDirection == .horizontal {
                segmented(l10n.t(.nrFlipAnimation), selection: $settings.flipMode,
                          options: ReaderFlipMode.allCases) { mode in
                    switch mode {
                    case .simulation: return l10n.t(.nrFlipSimulation)
                    case .cover: return l10n.t(.nrFlipCover)
                    case .slide: return l10n.t(.nrFlipSlide)
                    case .none: return l10n.t(.nrFlipNone)
                    }
                }
                Toggle(l10n.t(.nrTapReversed), isOn: $settings.tapZoneReversed)
                Toggle(l10n.t(.nrTapAllForward), isOn: $settings.tapAllForward)
            }
            intSlider(l10n.t(.nrAutoPageInterval), value: $settings.autoPageIntervalSec, range: 5...60, suffix: "s")
        }
    }

    // MARK: 屏幕

    private var screenSection: some View {
        section(l10n.t(.nrSectionScreen)) {
            Toggle(l10n.t(.nrImmersive), isOn: $settings.immersive)
            Toggle(l10n.t(.nrKeepScreenOn), isOn: $settings.keepScreenOn)
            Toggle(l10n.t(.nrTouchLocked), isOn: $settings.touchLocked)
            intSlider(l10n.t(.nrEyeBreak), value: $settings.eyeBreakReminderMinutes, range: 0...120, suffix: "min")
        }
    }

    // MARK: 图片

    private var imageSection: some View {
        section(l10n.t(.nrSectionImage)) {
            segmented(l10n.t(.nrImagePlacement), selection: $settings.imagePlacement,
                      options: ImagePlacement.allCases) { p in
                switch p {
                case .top: return l10n.t(.nrImageTop)
                case .center: return l10n.t(.nrImageCenter)
                case .bottom: return l10n.t(.nrImageBottom)
                }
            }
            segmented(l10n.t(.nrImageScale), selection: $settings.imageScaleMode,
                      options: ImageScaleMode.allCases) { m in
                switch m {
                case .fit: return l10n.t(.nrImageFit)
                case .fill: return l10n.t(.nrImageFill)
                case .original: return l10n.t(.nrImageOriginal)
                }
            }
            intSlider(l10n.t(.nrPreloadImages), value: $settings.preloadImageAhead, range: 0...8, suffix: "")
        }
    }

    // MARK: Building blocks

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.v3Text3)
            content()
        }
    }

    private func intSlider(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 14))
                Spacer()
                Text("\(value.wrappedValue)\(suffix)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.v3Text2)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
        }
    }

    private func floatSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 14))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.v3Text2)
            }
            Slider(value: value, in: range)
        }
    }

    private func segmented<T: Hashable>(_ label: String, selection: Binding<T>, options: [T], title: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 14))
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let selected = selection.wrappedValue == option
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(title(option))
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selected ? Color.accentColor : Theme.v3Surface, in: .rect(cornerRadius: 6))
                            .foregroundStyle(selected ? .white : Theme.v3Text1)
                    }
                }
            }
        }
    }
}
