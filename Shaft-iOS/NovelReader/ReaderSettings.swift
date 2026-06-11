import SwiftUI
import UIKit

// 1:1 port of Pixiv-Shaft `reader/settings` — ReaderTheme presets,
// PresetFonts, the persisted ReaderSettings model (same `r_*` keys,
// ranges and defaults as the Android MMKV store) and the derived TypeStyle.

// MARK: - Reading enums

enum ReadingDirection: String, CaseIterable {
    case horizontal, vertical
}

enum ReaderFlipMode: String, CaseIterable {
    case simulation, cover, slide, none
}

enum ImagePlacement: String, CaseIterable {
    case top, center, bottom
}

enum ImageScaleMode: String, CaseIterable {
    case fit, fill, original
}

// MARK: - Themes

struct ReaderTheme: Identifiable, Equatable {
    let id: String
    let nameKey: LocalizedKey
    let backgroundColor: UIColor
    let textColor: UIColor
    let secondaryTextColor: UIColor
    let accentColor: UIColor
    let linkColor: UIColor
    let selectionColor: UIColor
    let highlightColor: UIColor
    let dividerColor: UIColor
    let chapterTitleColor: UIColor
    let isDark: Bool

    static func == (a: ReaderTheme, b: ReaderTheme) -> Bool { a.id == b.id }

    // Exact ARGB values from upstream ReaderTheme.kt.
    static let kraft = ReaderTheme(
        id: "preset_kraft", nameKey: .nrThemeKraft,
        backgroundColor: UIColor(argb: 0xFFD9C49B), textColor: UIColor(argb: 0xFF3F3322),
        secondaryTextColor: UIColor(argb: 0xFF7A6A4B), accentColor: UIColor(argb: 0xFF8B5A2B),
        linkColor: UIColor(argb: 0xFF5E4626), selectionColor: UIColor(argb: 0x668B5A2B),
        highlightColor: UIColor(argb: 0x66FFCA28), dividerColor: UIColor(argb: 0xFFB8A77F),
        chapterTitleColor: UIColor(argb: 0xFF2D2316), isDark: false
    )
    static let white = ReaderTheme(
        id: "preset_white", nameKey: .nrThemeWhite,
        backgroundColor: UIColor(argb: 0xFFFFFFFF), textColor: UIColor(argb: 0xFF333333),
        secondaryTextColor: UIColor(argb: 0xFF888888), accentColor: UIColor(argb: 0xFF5B6EFF),
        linkColor: UIColor(argb: 0xFF2E7BFF), selectionColor: UIColor(argb: 0x665B6EFF),
        highlightColor: UIColor(argb: 0x66FFEB3B), dividerColor: UIColor(argb: 0xFFE4E4E4),
        chapterTitleColor: UIColor(argb: 0xFF222222), isDark: false
    )
    static let eyeProtection = ReaderTheme(
        id: "preset_eye_protection", nameKey: .nrThemeEye,
        backgroundColor: UIColor(argb: 0xFFC7EDCC), textColor: UIColor(argb: 0xFF2E3A2F),
        secondaryTextColor: UIColor(argb: 0xFF587159), accentColor: UIColor(argb: 0xFF2F7A49),
        linkColor: UIColor(argb: 0xFF1B5E20), selectionColor: UIColor(argb: 0x662F7A49),
        highlightColor: UIColor(argb: 0x66FFD54F), dividerColor: UIColor(argb: 0xFFA7D5AC),
        chapterTitleColor: UIColor(argb: 0xFF1F3020), isDark: false
    )
    static let parchment = ReaderTheme(
        id: "preset_parchment", nameKey: .nrThemeParchment,
        backgroundColor: UIColor(argb: 0xFFF5E8CF), textColor: UIColor(argb: 0xFF5A4A38),
        secondaryTextColor: UIColor(argb: 0xFF8A7558), accentColor: UIColor(argb: 0xFF8B6B3D),
        linkColor: UIColor(argb: 0xFF6B4A2F), selectionColor: UIColor(argb: 0x668B6B3D),
        highlightColor: UIColor(argb: 0x66FFCA28), dividerColor: UIColor(argb: 0xFFD4C094),
        chapterTitleColor: UIColor(argb: 0xFF3E2F1F), isDark: false
    )
    static let butter = ReaderTheme(
        id: "preset_butter", nameKey: .nrThemeButter,
        backgroundColor: UIColor(argb: 0xFFFDF6E3), textColor: UIColor(argb: 0xFF5C5343),
        secondaryTextColor: UIColor(argb: 0xFF9C8E72), accentColor: UIColor(argb: 0xFFB58900),
        linkColor: UIColor(argb: 0xFFCB7B00), selectionColor: UIColor(argb: 0x66B58900),
        highlightColor: UIColor(argb: 0x66FFEE58), dividerColor: UIColor(argb: 0xFFEEE2C4),
        chapterTitleColor: UIColor(argb: 0xFF3D3527), isDark: false
    )
    static let night = ReaderTheme(
        id: "preset_night", nameKey: .nrThemeNight,
        backgroundColor: UIColor(argb: 0xFF1B1B1B), textColor: UIColor(argb: 0xFFBDBDBD),
        secondaryTextColor: UIColor(argb: 0xFF7E7E7E), accentColor: UIColor(argb: 0xFF64B5F6),
        linkColor: UIColor(argb: 0xFF90CAF9), selectionColor: UIColor(argb: 0x6664B5F6),
        highlightColor: UIColor(argb: 0x66FFEE58), dividerColor: UIColor(argb: 0xFF2E2E2E),
        chapterTitleColor: UIColor(argb: 0xFFE0E0E0), isDark: true
    )
    static let charcoal = ReaderTheme(
        id: "preset_charcoal", nameKey: .nrThemeCharcoal,
        backgroundColor: UIColor(argb: 0xFF000000), textColor: UIColor(argb: 0xFF9E9E9E),
        secondaryTextColor: UIColor(argb: 0xFF616161), accentColor: UIColor(argb: 0xFFFF7043),
        linkColor: UIColor(argb: 0xFFFFAB91), selectionColor: UIColor(argb: 0x66FF7043),
        highlightColor: UIColor(argb: 0x66FFEE58), dividerColor: UIColor(argb: 0xFF1E1E1E),
        chapterTitleColor: UIColor(argb: 0xFFBDBDBD), isDark: true
    )

    static let presets: [ReaderTheme] = [kraft, white, eyeProtection, parchment, butter, night, charcoal]

    static func preset(id: String) -> ReaderTheme {
        presets.first { $0.id == id } ?? kraft
    }
}

/// Selection-toolbar highlight colors (exact ARGB from upstream HighlightColor).
enum ReaderHighlightColor: CaseIterable {
    case yellow, green, pink, blue

    var argb: UInt32 {
        switch self {
        case .yellow: return 0x66FFEB3B
        case .green: return 0x6681C784
        case .pink: return 0x66F48FB1
        case .blue: return 0x6664B5F6
        }
    }

    var nameKey: LocalizedKey {
        switch self {
        case .yellow: return .nrHighlightYellow
        case .green: return .nrHighlightGreen
        case .pink: return .nrHighlightPink
        case .blue: return .nrHighlightBlue
        }
    }
}

/// Search overlay highlight colors (fragment constants).
enum ReaderSearchColors {
    static let current = UIColor(argb: 0xAAFF9800)
    static let other = UIColor(argb: 0x66FFEB3B)
}

// MARK: - Fonts

struct PresetFont: Identifiable, Equatable {
    let id: String
    let nameKey: LocalizedKey

    /// Upstream maps font ids onto Android family names; we map onto the
    /// closest iOS equivalents (system designs / weights).
    func font(size: CGFloat, weight: Int, bold: Bool) -> UIFont {
        let uiWeight = PresetFont.uiWeight(for: weight, bold: bold)
        switch id {
        case "preset_sans_light":
            return .systemFont(ofSize: size, weight: bold ? .semibold : .light)
        case "preset_sans_medium":
            return .systemFont(ofSize: size, weight: bold ? .bold : .medium)
        case "preset_serif":
            return PresetFont.designFont(size: size, weight: uiWeight, design: .serif)
        case "preset_monospace":
            return PresetFont.designFont(size: size, weight: uiWeight, design: .monospaced)
        default: // system / preset_sans
            return .systemFont(ofSize: size, weight: uiWeight)
        }
    }

    private static func designFont(size: CGFloat, weight: UIFont.Weight, design: UIFontDescriptor.SystemDesign) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let desc = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: desc, size: size)
    }

    /// CSS weight 100–900 (+ bold flag, which fake-bolds below 500 upstream).
    static func uiWeight(for weight: Int, bold: Bool) -> UIFont.Weight {
        let effective = bold ? max(weight, 700) : weight
        switch effective {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    static let system = PresetFont(id: "system", nameKey: .nrFontSystem)
    static let builtIn: [PresetFont] = [
        system,
        PresetFont(id: "preset_sans", nameKey: .nrFontSans),
        PresetFont(id: "preset_sans_light", nameKey: .nrFontSansLight),
        PresetFont(id: "preset_sans_medium", nameKey: .nrFontSansMedium),
        PresetFont(id: "preset_serif", nameKey: .nrFontSerif),
        PresetFont(id: "preset_monospace", nameKey: .nrFontMonospace),
    ]

    static func byId(_ id: String) -> PresetFont {
        builtIn.first { $0.id == id } ?? system
    }
}

// MARK: - Settings store

/// Persisted reader settings — same keys / ranges / defaults as upstream
/// `ReaderSettings.kt` (MMKV "novel_reader_v3"), stored in UserDefaults with
/// an `nrv3_` namespace prefix. Volume-key flip / screen-orientation /
/// TTS settings are Android-only and intentionally not ported.
@MainActor
@Observable
final class NovelReaderSettings {
    static let shared = NovelReaderSettings()

    @ObservationIgnored private let d = UserDefaults.standard
    private static let prefix = "nrv3_"

    // Typography
    var fontSizeSp: Int { didSet { set(fontSizeSp.clamped(12, 36), oldValue, "r_font_size") } }
    var lineSpacing: Double { didSet { set(lineSpacing.clamped(1.0, 2.8), oldValue, "r_line_spacing") } }
    var paragraphSpacingLines: Double { didSet { set(paragraphSpacingLines.clamped(0, 2.5), oldValue, "r_paragraph_spacing") } }
    var horizontalMarginDp: Int { didSet { set(horizontalMarginDp.clamped(0, 64), oldValue, "r_h_margin") } }
    var verticalMarginDp: Int { didSet { set(verticalMarginDp.clamped(0, 96), oldValue, "r_v_margin") } }
    var firstLineIndent: Int { didSet { set(firstLineIndent.clamped(0, 4), oldValue, "r_indent") } }
    var letterSpacing: Double { didSet { set(letterSpacing.clamped(-0.05, 0.25), oldValue, "r_letter_spacing") } }
    var boldText: Bool { didSet { set(boldText, oldValue, "r_bold") } }
    var fontId: String { didSet { set(fontId, oldValue, "r_font_id") } }
    var fontWeight: Int { didSet { set(fontWeight.clamped(100, 900), oldValue, "r_font_weight") } }

    // Theme
    var themeId: String { didSet { set(themeId, oldValue, "r_theme_id") } }
    var followSystemDarkMode: Bool { didSet { set(followSystemDarkMode, oldValue, "r_follow_dark") } }
    /// Last non-dark theme — restored by the bottom-bar day/night toggle.
    var lastLightThemeId: String { didSet { set(lastLightThemeId, oldValue, "r_last_light_theme") } }

    // Brightness
    var useSystemBrightness: Bool { didSet { set(useSystemBrightness, oldValue, "r_sys_brightness") } }
    var customBrightness: Double { didSet { set(customBrightness.clamped(0.01, 1.0), oldValue, "r_brightness") } }
    var warmFilterStrength: Double { didSet { set(warmFilterStrength.clamped(0, 0.6), oldValue, "r_warm_filter") } }

    // Flip / interaction
    var readingDirection: ReadingDirection { didSet { set(readingDirection.rawValue, oldValue.rawValue, "r_reading_direction") } }
    var flipMode: ReaderFlipMode { didSet { set(flipMode.rawValue, oldValue.rawValue, "r_flip_mode") } }
    var tapZoneReversed: Bool { didSet { set(tapZoneReversed, oldValue, "r_tap_reversed") } }
    var autoPageIntervalSec: Int { didSet { set(autoPageIntervalSec.clamped(5, 60), oldValue, "r_auto_page_interval") } }

    // Screen
    var immersive: Bool { didSet { set(immersive, oldValue, "r_immersive") } }
    var keepScreenOn: Bool { didSet { set(keepScreenOn, oldValue, "r_keep_screen_on") } }
    var touchLocked: Bool { didSet { set(touchLocked, oldValue, "r_touch_locked") } }
    var eyeBreakReminderMinutes: Int { didSet { set(eyeBreakReminderMinutes.clamped(0, 120), oldValue, "r_eye_remind") } }

    // Image
    var imagePlacement: ImagePlacement { didSet { set(imagePlacement.rawValue, oldValue.rawValue, "r_img_placement") } }
    var imageScaleMode: ImageScaleMode { didSet { set(imageScaleMode.rawValue, oldValue.rawValue, "r_img_scale") } }
    var preloadImageAhead: Int { didSet { set(preloadImageAhead.clamped(0, 8), oldValue, "r_preload_ahead") } }

    private init() {
        let d = UserDefaults.standard
        func i(_ key: String, _ def: Int) -> Int { d.object(forKey: Self.prefix + key) == nil ? def : d.integer(forKey: Self.prefix + key) }
        func f(_ key: String, _ def: Double) -> Double { d.object(forKey: Self.prefix + key) == nil ? def : d.double(forKey: Self.prefix + key) }
        func b(_ key: String, _ def: Bool) -> Bool { d.object(forKey: Self.prefix + key) == nil ? def : d.bool(forKey: Self.prefix + key) }
        func s(_ key: String, _ def: String) -> String { d.string(forKey: Self.prefix + key) ?? def }

        fontSizeSp = i("r_font_size", 18)
        lineSpacing = f("r_line_spacing", 1.6)
        paragraphSpacingLines = f("r_paragraph_spacing", 0.8)
        horizontalMarginDp = i("r_h_margin", 20)
        verticalMarginDp = i("r_v_margin", 24)
        firstLineIndent = i("r_indent", 2)
        letterSpacing = f("r_letter_spacing", 0)
        boldText = b("r_bold", false)
        fontId = s("r_font_id", PresetFont.system.id)
        fontWeight = i("r_font_weight", 400)
        themeId = s("r_theme_id", ReaderTheme.kraft.id)
        followSystemDarkMode = b("r_follow_dark", false)
        lastLightThemeId = s("r_last_light_theme", ReaderTheme.kraft.id)
        useSystemBrightness = b("r_sys_brightness", true)
        customBrightness = f("r_brightness", 0.5)
        warmFilterStrength = f("r_warm_filter", 0)
        readingDirection = ReadingDirection(rawValue: s("r_reading_direction", "horizontal")) ?? .horizontal
        flipMode = ReaderFlipMode(rawValue: s("r_flip_mode", "simulation")) ?? .simulation
        tapZoneReversed = b("r_tap_reversed", false)
        autoPageIntervalSec = i("r_auto_page_interval", 15)
        immersive = b("r_immersive", true)
        keepScreenOn = b("r_keep_screen_on", true)
        touchLocked = b("r_touch_locked", false)
        eyeBreakReminderMinutes = i("r_eye_remind", 30)
        imagePlacement = ImagePlacement(rawValue: s("r_img_placement", "center")) ?? .center
        imageScaleMode = ImageScaleMode(rawValue: s("r_img_scale", "fit")) ?? .fit
        preloadImageAhead = i("r_preload_ahead", 2)
    }

    private func set<T: Equatable>(_ value: T, _ old: T, _ key: String) {
        guard value != old || d.object(forKey: Self.prefix + key) == nil else { return }
        d.set(value, forKey: Self.prefix + key)
    }

    /// Theme honoring the follow-system-dark override.
    func effectiveTheme(systemIsDark: Bool) -> ReaderTheme {
        let theme = ReaderTheme.preset(id: themeId)
        if followSystemDarkMode && systemIsDark && !theme.isDark {
            return .night
        }
        return theme
    }

    /// Bottom-bar 夜间/日间 toggle: dark → restore last light theme,
    /// light → remember it and switch to night.
    func toggleDayNight() {
        let theme = ReaderTheme.preset(id: themeId)
        if theme.isDark {
            themeId = lastLightThemeId
        } else {
            lastLightThemeId = themeId
            themeId = ReaderTheme.night.id
        }
    }

    /// Layout-affecting values bundled for cheap Equatable diffing — when this
    /// snapshot changes the reader re-paginates; theme-only changes restyle.
    struct LayoutSnapshot: Equatable {
        var fontSizeSp: Int
        var lineSpacing: Double
        var paragraphSpacingLines: Double
        var horizontalMarginDp: Int
        var verticalMarginDp: Int
        var firstLineIndent: Int
        var letterSpacing: Double
        var boldText: Bool
        var fontId: String
        var fontWeight: Int
        var readingDirection: ReadingDirection
        var imagePlacement: ImagePlacement
        var imageScaleMode: ImageScaleMode
    }

    var layoutSnapshot: LayoutSnapshot {
        LayoutSnapshot(
            fontSizeSp: fontSizeSp, lineSpacing: lineSpacing,
            paragraphSpacingLines: paragraphSpacingLines,
            horizontalMarginDp: horizontalMarginDp, verticalMarginDp: verticalMarginDp,
            firstLineIndent: firstLineIndent, letterSpacing: letterSpacing,
            boldText: boldText, fontId: fontId, fontWeight: fontWeight,
            readingDirection: readingDirection,
            imagePlacement: imagePlacement, imageScaleMode: imageScaleMode
        )
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

// MARK: - TypeStyle

/// Resolved typography + palette handed to the paginator and renderers —
/// mirror of upstream TypeStyle (chapter 1.55×, caption 0.82×, fixed line
/// height = round(fontHeight × multiplier), paragraph spacing in font
/// heights, first-line indent in em).
struct ReaderTypeStyle {
    let bodyFont: UIFont
    let chapterFont: UIFont
    let captionFont: UIFont
    /// Kern in points (em setting × font size).
    let kern: CGFloat
    let lineHeight: CGFloat
    let chapterLineHeight: CGFloat
    let paragraphSpacing: CGFloat
    let firstLineIndent: CGFloat
    let chapterTopGap: CGFloat
    let chapterBottomGap: CGFloat
    let imagePlacement: ImagePlacement
    let imageScaleMode: ImageScaleMode
    let theme: ReaderTheme

    var fontHeight: CGFloat { bodyFont.ascender - bodyFont.descender }

    @MainActor
    static func resolve(settings: NovelReaderSettings, theme: ReaderTheme) -> ReaderTypeStyle {
        let size = CGFloat(settings.fontSizeSp)
        let preset = PresetFont.byId(settings.fontId)
        let body = preset.font(size: size, weight: settings.fontWeight, bold: settings.boldText)
        let chapter = preset.font(size: size * 1.55, weight: max(settings.fontWeight, 700), bold: true)
        let caption = preset.font(size: size * 0.82, weight: settings.fontWeight, bold: false)
        let fontHeight = body.ascender - body.descender
        let chapterHeight = chapter.ascender - chapter.descender
        return ReaderTypeStyle(
            bodyFont: body,
            chapterFont: chapter,
            captionFont: caption,
            kern: CGFloat(settings.letterSpacing) * size,
            lineHeight: (fontHeight * CGFloat(settings.lineSpacing)).rounded(),
            chapterLineHeight: (chapterHeight * 1.15).rounded(),
            paragraphSpacing: fontHeight * CGFloat(settings.paragraphSpacingLines),
            firstLineIndent: size * CGFloat(settings.firstLineIndent),
            chapterTopGap: chapterHeight * 0.8,
            chapterBottomGap: chapterHeight * 1.2,
            imagePlacement: settings.imagePlacement,
            imageScaleMode: settings.imageScaleMode,
            theme: theme
        )
    }

    /// Attributes for body text. `indentFirstLine` applies the em-indent
    /// LeadingMargin equivalent; fixed line height pins every line box so the
    /// paginator's slicing math is exact.
    func bodyAttributes(indentFirstLine: Bool) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.lineBreakMode = .byWordWrapping
        p.alignment = .natural
        if indentFirstLine, firstLineIndent > 0 {
            p.firstLineHeadIndent = firstLineIndent
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: theme.textColor,
            .paragraphStyle: p,
        ]
        if kern != 0 { attrs[.kern] = kern }
        return attrs
    }

    func chapterAttributes() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = chapterLineHeight
        p.maximumLineHeight = chapterLineHeight
        p.lineBreakMode = .byWordWrapping
        p.alignment = .center
        return [
            .font: chapterFont,
            .foregroundColor: theme.chapterTitleColor,
            .paragraphStyle: p,
        ]
    }
}

extension UIColor {
    /// Build from a `0xAARRGGBB` literal — keeps the upstream theme values readable.
    convenience init(argb: UInt32) {
        self.init(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }
}
