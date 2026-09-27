import Observation
import SwiftUI
import UIKit

/// 「标签原文亮暗度」（2026-09-24）—— 1:1 port of upstream `TagLegibilityPrefs` +
/// `V3TagLegibility` + `V3Palette.tagTextColor` / `enhanceLegibility` + `ApcaContrast`.
///
/// Device-local on purpose (UserDefaults, never in backups): legibility is an
/// "eyes × screen" result, a value that suits one device may not suit another.
/// Day and night are two independent strengths, 0…100, default 0 (= bit-for-bit
/// the pre-feature colour). Only the tag's **original text** follows the boost;
/// translation / delete glyphs keep the un-boosted `v3TagText` so the chip keeps
/// a saturated anchor.
@MainActor
@Observable
final class TagLegibility {
    static let shared = TagLegibility()

    private static let lightKey = "tag_legibility_boost_light"
    private static let darkKey = "tag_legibility_boost_dark"

    private(set) var light: Int
    private(set) var dark: Int

    private init() {
        light = min(max(UserDefaults.standard.integer(forKey: Self.lightKey), 0), 100)
        dark = min(max(UserDefaults.standard.integer(forKey: Self.darkKey), 0), 100)
    }

    /// Both written together, clamped to 0…100.
    func save(light: Int, dark: Int) {
        self.light = min(max(light, 0), 100)
        self.dark = min(max(dark, 0), 100)
        UserDefaults.standard.set(self.light, forKey: Self.lightKey)
        UserDefaults.standard.set(self.dark, forKey: Self.darkKey)
    }

    /// Tag original-text colour for the current strengths; re-renders when
    /// they change (both strengths are read here, so SwiftUI tracks them).
    var originalText: Color {
        let lightBoost = Double(light) / 100, darkBoost = Double(dark) / 100
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return Self.originalTextUIColor(isDark: isDark, boost: isDark ? darkBoost : lightBoost)
        })
    }

    // MARK: Colour math

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: UIColor] = [:]

    /// `V3Palette(primary, isDark, boost).textTag`: the base tag colour pushed
    /// towards the APCA body-text line (Lc 75) against the chip's own surface —
    /// the 20 % theme tint composited over the card fill.
    nonisolated static func originalTextUIColor(isDark: Bool, boost: Double) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let base = UIColor(Theme.v3TagText).resolvedColor(with: traits)
        guard boost > 0 else { return base }
        let key = "\(isDark)-\(Int((boost * 100).rounded()))"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }
        let card = UIColor(Theme.v3CardFill).resolvedColor(with: traits)
        let bg = composite(UIColor(Theme.brand), alpha: 0.20, over: card)
        let result = enhanceLegibility(base, bg: bg, goLighter: isDark, boost: boost)
        cache[key] = result
        return result
    }

    /// Target = `current + boost × |75 − current|` (absolute, so the slider
    /// responds on every theme); only HSL lightness moves, in 0.005 steps.
    nonisolated private static func enhanceLegibility(_ base: UIColor, bg: UIColor, goLighter: Bool, boost: Double) -> UIColor {
        let strength = min(max(boost, 0), 1)
        let current = abs(ApcaContrast.lc(text: base, background: bg))
        let target = current + strength * abs(ApcaContrast.bodyTextMin - current)
        if target <= current { return base }
        var (h, s, l) = hsl(base)
        var result = base
        for _ in 0..<120 {
            l = min(max(l + (goLighter ? 0.005 : -0.005), 0), 1)
            result = fromHSL(h, s, l)
            if abs(ApcaContrast.lc(text: result, background: bg)) >= target { return result }
            if l <= 0 || l >= 1 { return result }
        }
        return result
    }

    nonisolated static func composite(_ fg: UIColor, alpha: CGFloat, over bg: UIColor) -> UIColor {
        var fr: CGFloat = 0, fgG: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bgG: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        fg.getRed(&fr, green: &fgG, blue: &fb, alpha: &fa)
        bg.getRed(&br, green: &bgG, blue: &bb, alpha: &ba)
        return UIColor(red: fr * alpha + br * (1 - alpha), green: fgG * alpha + bgG * (1 - alpha),
                       blue: fb * alpha + bb * (1 - alpha), alpha: 1)
    }

    /// `ColorUtils.colorToHSL`.
    nonisolated private static func hsl(_ c: UIColor) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let mx = Double(max(r, g, b)), mn = Double(min(r, g, b))
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == Double(r) { h = (Double(g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == Double(g) { h = Double(b - r) / d + 2 }
        else { h = Double(r - g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    /// `ColorUtils.HSLToColor`.
    nonisolated private static func fromHSL(_ h: Double, _ s: Double, _ l: Double) -> UIColor {
        let c = (1 - abs(2 * l - 1)) * s
        let m = l - c / 2
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch Int(h / 60) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func q(_ v: Double) -> CGFloat { CGFloat(min(max(((v + m) * 255).rounded(), 0), 255) / 255) }
        return UIColor(red: q(r), green: q(g), blue: q(b), alpha: 1)
    }
}

/// APCA-W3 0.1.98G-4g Lc (upstream `ApcaContrast`). Light-on-dark is negative;
/// compare by absolute value.
enum ApcaContrast {
    /// Body-text line — tag chips are 11.5–13pt text.
    static let bodyTextMin = 75.0

    static func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> Double {
            let v = Double((c * 255).rounded()) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126729 * lin(r) + 0.7151522 * lin(g) + 0.0721750 * lin(b)
    }

    private static func softClamp(_ y: Double) -> Double { y < 0.022 ? y + pow(0.022 - y, 1.414) : y }

    static func lc(text: UIColor, background: UIColor) -> Double {
        let yt = softClamp(luminance(text)), yb = softClamp(luminance(background))
        if abs(yb - yt) < 0.0005 { return 0 }
        if yb > yt {
            let s = (pow(yb, 0.56) - pow(yt, 0.57)) * 1.14
            return s < 0.1 ? 0 : (s - 0.027) * 100
        } else {
            let s = (pow(yb, 0.65) - pow(yt, 0.62)) * 1.14
            return s > -0.1 ? 0 : (s + 0.027) * 100
        }
    }
}

// MARK: - Settings sheet (dialog_tag_legibility_boost)

/// Two sliders (白天 / 黑暗), each with a live preview row on the real page
/// surface of *that* mode: the left chip is always the un-boosted original,
/// the right one follows the slider — before / after side by side. Cancel
/// saves nothing; 确定 writes both.
struct TagLegibilitySheet: View {
    @State private var light: Int
    @State private var dark: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    init() {
        _light = State(initialValue: TagLegibility.shared.light)
        _dark = State(initialValue: TagLegibility.shared.dark)
    }

    static func label(dark: Bool, value: Int, l10n: OnboardingStore) -> String {
        if value <= 0 { return l10n.t(dark ? .tagLegibilityBoostNoneDark : .tagLegibilityBoostNoneLight) }
        return String(format: l10n.t(dark ? .tagLegibilityBoostPercentDark : .tagLegibilityBoostPercentLight), value)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(l10n.t(.tagLegibilityBoostHint))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text2)
                    sliderBlock(dark: false, value: $light)
                        .padding(.top, 16)
                    Theme.v3Surface2.frame(height: 1).padding(.top, 18)
                    sliderBlock(dark: true, value: $dark)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .navigationTitle(l10n.t(.tagLegibilityBoost))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t(.stSure)) {
                        TagLegibility.shared.save(light: light, dark: dark)
                        dismiss()
                    }
                }
            }
        }
    }

    private func sliderBlock(dark isDark: Bool, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(l10n.t(isDark ? .tagLegibilityBoostDark : .tagLegibilityBoostLight))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.v3Text1)
                Spacer()
                Text(Self.label(dark: isDark, value: value.wrappedValue, l10n: l10n))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.brand)
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: 0...100, step: 1)
                .tint(Theme.brand)
            HStack(spacing: 12) {
                previewChip(isDark: isDark, boost: 0)
                previewChip(isDark: isDark, boost: Double(value.wrappedValue) / 100)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The chip's tint is translucent, so preview on the real page surface of that mode.
            .background(RoundedRectangle(cornerRadius: 12).fill(isDark ? Color(hex: 0x08080C) : Color(hex: 0xFAFAFA)))
            .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }

    private func previewChip(isDark: Bool, boost: Double) -> some View {
        Text(l10n.t(.tagLegibilityBoostPreviewTag))
            .font(.system(size: 13))
            .foregroundStyle(Color(uiColor: TagLegibility.originalTextUIColor(isDark: isDark, boost: boost)))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.v3TagChipFill, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.v3TagChipBorder, lineWidth: 1))
    }
}
