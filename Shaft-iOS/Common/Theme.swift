import SwiftUI
import UIKit

/// Shared design palette ported from the **shaft-web** color scheme
/// (`app/globals.css` `@theme`). The app's `AccentColor` asset is set to
/// `brand`, so most `.tint` / `.accentColor` surfaces pick it up automatically;
/// this enum is for the spots that want the gradient or the cyan/glow highlights.
enum Theme {
    /// Primary brand violet — `#7c6cff` (matches the asset `AccentColor`).
    static let brand = Color(hex: 0x7C6CFF)
    /// Secondary brand indigo — gradient end, `#5b6ee1`.
    static let brand2 = Color(hex: 0x5B6EE1)
    /// Cyan highlight / link accent — `#22d3ee`.
    static let accentCyan = Color(hex: 0x22D3EE)
    /// Purple glow used in the web's shimmer/aurora — `#a78bfa`.
    static let glow = Color(hex: 0xA78BFA)
    /// Deep ink backgrounds — `#07060f` / `#0c0a18`.
    static let ink = Color(hex: 0x07060F)
    static let ink2 = Color(hex: 0x0C0A18)
    /// Pixiv's official blue, for the OAuth affordance — `#0096fa`.
    static let pixivBlue = Color(hex: 0x0096FA)

    /// Primary-button gradient: brand violet → indigo (web's auth/CTA buttons).
    static let brandGradient = LinearGradient(
        colors: [brand, brand2],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Aurora highlight gradient: violet → glow → cyan (web's progress bar / shimmer).
    static let glowGradient = LinearGradient(
        colors: [brand, glow, accentCyan],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Soft brand-tinted shadow for elevated brand buttons.
    static let brandShadow = brand.opacity(0.45)

    // MARK: - V3 detail palette
    //
    // Ported from Pixiv-Shaft `values/colors.xml` + `values-night` `v3_*`. Text
    // ramps are the same ink/paper hue at descending opacity; surfaces/borders
    // are near-transparent so the glass cards read against the dark detail bg.

    static let v3Text1 = Color(light: 0x1A1A2E, dark: 0xF4F4F8)
    static let v3Text2 = Color(light: 0x1A1A2E, dark: 0xF4F4F8, lightAlpha: 0.60, darkAlpha: 0.62)
    static let v3Text3 = Color(light: 0x1A1A2E, dark: 0xF4F4F8, lightAlpha: 0.33, darkAlpha: 0.36)
    static let v3Border = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.06)
    static let v3Surface = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.035, darkAlpha: 0.045)

    static let v3Pink = Color(hex: 0xE0246A)
    static let v3Blue = Color(hex: 0x2B6FCC)
    static let v3Green = Color(hex: 0x1DA88A)
    static let v3Purple = Color(hex: 0x7C5CC8)
    static let v3Ambient = Color(light: 0x5B4CA0, dark: 0x7C6BC4)

    /// Stat number gradients (views = violet→rose, bookmarks = indigo→violet).
    static let v3ViewsGradient = LinearGradient(
        colors: [Color(hex: 0x9055CC), Color(hex: 0xC05588)],
        startPoint: .leading, endPoint: .trailing
    )
    static let v3BookmarksGradient = LinearGradient(
        colors: [Color(hex: 0x5566CC), Color(hex: 0x7766CC)],
        startPoint: .leading, endPoint: .trailing
    )
}

extension View {
    /// V3 glass card: faint translucent fill + hairline border, rounded. Mirrors
    /// `v3_glass_surface` (r=20) / `v3_glass_surface_xl` (r=28).
    func v3Glass(corner: CGFloat = 20) -> some View {
        self
            .background(Theme.v3Surface, in: .rect(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Theme.v3Border, lineWidth: 1))
    }
}

extension Color {
    /// Build an sRGB color from a `0xRRGGBB` literal — keeps the web hex values readable.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Adaptive sRGB color resolving a different `0xRRGGBB` literal (and optional
    /// opacity) for light vs dark — mirrors `values/` + `values-night/` pairs.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let h = isDark ? dark : light
            let a = isDark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((h >> 16) & 0xFF) / 255,
                green: CGFloat((h >> 8) & 0xFF) / 255,
                blue: CGFloat(h & 0xFF) / 255,
                alpha: a
            )
        })
    }
}
