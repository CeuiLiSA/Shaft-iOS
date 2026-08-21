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

    /// Page background — `v3_bg` (#FAFAFA / #08080C). The user-profile banner
    /// gradient and the avatar border must resolve to this exact color.
    static let v3Bg = Color(light: 0xFAFAFA, dark: 0x08080C)
    /// Premium gold pair — avatar ring `#FFD700`, badge/official `#FFC233`.
    static let v3GoldRing = Color(hex: 0xFFD700)
    static let v3Gold = Color(hex: 0xFFC233)

    static let v3Text1 = Color(light: 0x1A1A2E, dark: 0xF4F4F8)
    static let v3Text2 = Color(light: 0x1A1A2E, dark: 0xF4F4F8, lightAlpha: 0.60, darkAlpha: 0.62)
    static let v3Text3 = Color(light: 0x1A1A2E, dark: 0xF4F4F8, lightAlpha: 0.33, darkAlpha: 0.36)
    static let v3Border = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.06)
    /// witstudio `wit_surface_1` (#08000000 / #08FFFFFF), `wit_surface_2`
    /// (#0E000000 / #0EFFFFFF), `wit_border_1` (#0A000000 / #0AFFFFFF) — the
    /// chip fill / thumbnail placeholder / chip hairline on the Discover tab.
    static let v3Surface1 = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 8 / 255, darkAlpha: 8 / 255)
    static let v3Surface2 = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 14 / 255, darkAlpha: 14 / 255)
    static let v3Border1 = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 10 / 255, darkAlpha: 10 / 255)
    /// witstudio `wit_border_2` (#0F000000 / #0FFFFFFF) — avatar ring on timeline cards.
    static let v3Border2 = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 15 / 255, darkAlpha: 15 / 255)
    /// Legacy `light_bg` (#f2f2f2 / #1B1B1B) — Glide placeholder under covers.
    static let lightBg = Color(light: 0xF2F2F2, dark: 0x1B1B1B)
    /// `V3Palette.floatingPillContent`: white on dark; brand clamped to L≤0.40
    /// (`#1600CC`) on light so it reads on the tinted pill.
    static let v3FloatingPillContent = Color(light: 0x1600CC, dark: 0xFFFFFF)
    static let v3Surface = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.035, darkAlpha: 0.045)
    /// Search V3's runtime `V3Palette.cardFill` derived from brand `#7C6CFF`:
    /// HSL saturation × 0.50 + L=0.96 in light mode, × 0.16 + L=0.135 in dark.
    static let v3CardFill = Color(light: 0xF1F0FA, dark: 0x1E1D28)
    /// Matching 12% runtime hairline. Light mode first clamps brand HSL L to
    /// 0.40 (`#1600CC`); dark mode already satisfies the L≥0.60 clamp.
    static let v3CardHairline = Color(
        light: 0x1600CC, dark: 0x7C6CFF,
        lightAlpha: 0.12, darkAlpha: 0.12
    )
    /// `V3Palette.textAccent` against the card fill. Light clamps L to 0.40;
    /// dark needs one 0.02 contrast-correction step to reach 4.5:1.
    static let v3TextAccent = Color(light: 0x1600CC, dark: 0x8576FF)
    /// `V3Palette.textTag` — tag-chip label on the `tagLockedBg` pill: brand
    /// clamped to L≤0.38 (light) / L≥0.70 (dark, already satisfied).
    static let v3TagText = Color(light: 0x1500C2, dark: 0x7C6CFF)

    /// V3 detail floating action bar (`bg_v3_fab_bar`): fixed `#CC1A1A2E`
    /// capsule in BOTH light and dark (the upstream drawable isn't
    /// theme-aware), white icons, 20%-white divider (`#33FFFFFF`); the
    /// bookmark heart lights up `has_bookmarked` red when bookmarked.
    static let v3FabBar = Color(hex: 0x1A1A2E, alpha: 0.80)
    static let v3FabDivider = Color.white.opacity(0.20)
    static let v3Bookmarked = Color(hex: 0xFA3A3A)

    /// witstudio `wit_pink` / `wit_blue` / `wit_green` / `wit_purple`, which the
    /// detail chips read through `ctx.getColor` — so they follow the night
    /// resource set (`values-night/wit_colors.xml:32-36`), not just the day one.
    static let v3Pink = Color(light: 0xE0246A, dark: 0xFF2D78)
    static let v3Blue = Color(light: 0x2B6FCC, dark: 0x3D8BFD)
    static let v3Green = Color(light: 0x1DA88A, dark: 0x2DD4A8)
    static let v3Purple = Color(light: 0x7C5CC8, dark: 0x9F7AEA)
    static let v3Ambient = Color(light: 0x5B4CA0, dark: 0x7C6BC4)

    // MARK: - ArtworkV3 detail extras
    //
    // Everything below is resolved from `V3Palette` (which derives the whole V3
    // ramp from `?attr/colorPrimary` at runtime) against our brand `#7C6CFF`,
    // or straight from `values/colors.xml` + `values-night/`.

    /// `V3Palette.tagLockedBg`: brand at 8 % with a 15 % hairline, r=999.
    /// (The matching `v3TagText` label color is declared above.)
    static let v3TagChipFill = brand.opacity(0.08)
    static let v3TagChipBorder = brand.opacity(0.15)

    /// `V3Palette.seriesStripText` — white on dark; brand clamped to L≤0.30
    /// (`#110099`) on light, where the tinted strip would swallow white.
    static let v3SeriesStripText = Color(light: 0x110099, dark: 0xFFFFFF)
    /// `V3Palette.textSecondary` — the un-follow button's label.
    static let v3TextSecondary = Color(
        light: 0x1300B3, dark: 0x8070FF,
        lightAlpha: 0.90, darkAlpha: 0.90
    )

    /// `v3_nav_btn_bg` (#33000000 / #59000000) — the 3dp meta-row separator dots.
    static let v3NavBtnBg = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.20, darkAlpha: 0.35)
    /// `has_downloaded` (#2ECC71) — the download FAB once the work is on disk.
    static let v3HasDownloaded = Color(hex: 0x2ECC71)
    /// `wit_menu_bg` (#F5F5F5 / #1A1A2E) — the V3 menu dialog / sheet plate.
    static let v3MenuBg = Color(light: 0xF5F5F5, dark: 0x1A1A2E)
    /// `divider_color` equivalent for the hairline between stacked pages.
    static let v3PageDivider = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)

    /// `v3_danger` (#E5484D / #FF6369) — the comment row's 删除 action.
    static let v3Danger = Color(light: 0xE5484D, dark: 0xFF6369)

    /// Stat number gradients (views = violet→rose, bookmarks = indigo→violet),
    /// `values/colors.xml:271-276` + `values-night/colors.xml:114-119`.
    ///
    /// `GradientTextView` defaults to `gtv_angle=135°`, which its shader math
    /// turns into start (0.854w, 0.854h) → end (0.146w, 0.146h) — i.e. the
    /// start color sits bottom-**right** and runs to top-left, not the plain
    /// left→right ramp this used to draw.
    static let v3ViewsGradient = LinearGradient(
        colors: [Color(light: 0x9055CC, dark: 0xC084FC), Color(light: 0xC05588, dark: 0xE879A8)],
        startPoint: .bottomTrailing, endPoint: .topLeading
    )
    static let v3BookmarksGradient = LinearGradient(
        colors: [Color(light: 0x5566CC, dark: 0x818CF8), Color(light: 0x7766CC, dark: 0xA78BFA)],
        startPoint: .bottomTrailing, endPoint: .topLeading
    )
}

extension View {
    /// V3 glass card: faint translucent fill + hairline border, rounded. Mirrors
    /// `v3_glass_surface` (r=20) / `v3_glass_surface_xl` (r=28).
    /// Both drawables fill with `v3_surface_1` (8/255) and differ only in the
    /// stroke: `v3_glass_surface` (r=20) uses `v3_border_1` (10/255), the XL
    /// one `v3_border_2` (15/255). The old `v3Surface`/`v3Border` pair was an
    /// eyeballed approximation — 0.045 fill in dark is 43 % brighter than
    /// upstream and 0.06 stroke 53 % stronger than the r=20 drawable's.
    func v3Glass(corner: CGFloat = 20) -> some View {
        self
            .background(Theme.v3Surface1, in: .rect(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(corner >= 28 ? Theme.v3Border2 : Theme.v3Border1, lineWidth: 1)
            )
    }
}

extension Color {
    /// `V3Palette.hueShift`: rotate the hue by `degrees` (HSL/HSB hue is the
    /// same angle), keeping saturation/lightness/alpha. Used for the brand
    /// gradients (`seriesStripBg` +25°, `seriesIconBg` +40°).
    func hueShifted(_ degrees: Double) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        var nh = (h + degrees / 360).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return Color(uiColor: UIColor(hue: nh, saturation: s, brightness: b, alpha: a))
    }

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
