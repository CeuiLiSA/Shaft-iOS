import UIKit

/// Android V3Palette and DiscoverSocialColors, including integer alpha compositing.
/// The default accent matches Android AppTheme; all roles derive from that input.
struct DiscoverSocialPalette {
    let dark: Bool
    var accent: UInt32 = 0x686BDD
    var primary: UIColor { color(accent) }
    var background: UIColor { color(dark ? 0x08080C : 0xFAFAFA) }
    var ink: UIColor { color(dark ? 0xF4F4F8 : 0x1A1A2E) }
    var card: UIColor {
        let desaturated = hslColor(primary, saturationFactor: dark ? 0.16 : 0.50)
        return hslColor(desaturated, lightness: dark ? 0.135 : 0.96)
    }
    var hairline: UIColor { clampedAccent(dark ? 0.60 : 0.40).withAlphaComponent(30 / 255) }
    var chat: UIColor { composite(alpha(0.20), over: card) }
    var textAccent: UIColor {
        let value = clampedAccent(dark ? 0.60 : 0.40)
        if contrast(value, card) >= 4.5 { return value }
        let start = hsl(value).2
        for step in 1...40 {
            let candidate = hslColor(value, lightness: min(1, max(0, start + (dark ? 1 : -1) * Double(step) * 0.02)))
            if contrast(candidate, card) >= 4.5 { return candidate }
        }
        return dark ? .white : .black
    }
    var onPrimary: UIColor {
        readable(luminance(primary) < 0.5 ? .white : hslColor(primary, lightness: min(hsl(primary).2, 0.25)), on: primary)
    }
    func alpha(_ value: Double) -> UIColor { primary.withAlphaComponent(CGFloat(Int(value * 255)) / 255) }
    func accent(on fill: UIColor) -> UIColor { readable(textAccent, on: fill) }
    func secondary(on fill: UIColor) -> UIColor {
        readable(ink.withAlphaComponent(CGFloat(dark ? 158 : 153) / 255), on: fill)
    }
    func composite(_ foreground: UIColor, over background: UIColor) -> UIColor {
        let f = channels(foreground), b = channels(background), a = Int((f.3 * 255).rounded())
        func channel(_ fg: Double, _ bg: Double) -> Double {
            Double((Int((fg * 255).rounded()) * a + Int((bg * 255).rounded()) * (255 - a)) / 255) / 255
        }
        return UIColor(red: channel(f.0, b.0), green: channel(f.1, b.1), blue: channel(f.2, b.2), alpha: 1)
    }
    private func clampedAccent(_ value: Double) -> UIColor {
        hslColor(primary, lightness: dark ? max(hsl(primary).2, value) : min(hsl(primary).2, value))
    }
    private func readable(_ foreground: UIColor, on background: UIColor) -> UIColor {
        let opaque = composite(foreground, over: background)
        if contrast(opaque, background) >= 4.5 { return opaque }
        let target = contrast(.white, background) > contrast(.black, background) ? 1.0 : 0.0
        let rgb = channels(opaque)
        for step in 1...100 {
            let fraction = Double(step) / 100
            func blend(_ x: Double) -> Double { floor((x * (1 - fraction) + target * fraction) * 255) / 255 }
            let candidate = UIColor(red: blend(rgb.0), green: blend(rgb.1), blue: blend(rgb.2), alpha: 1)
            if contrast(candidate, background) >= 4.5 { return candidate }
        }
        return target == 1 ? .white : .black
    }
    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    private func luminance(_ color: UIColor) -> Double {
        let c = channels(color)
        func linear(_ x: Double) -> Double { x < 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return linear(c.0) * 0.2126 + linear(c.1) * 0.7152 + linear(c.2) * 0.0722
    }
    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }
    private func channels(_ color: UIColor) -> (Double, Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
    private func hsl(_ color: UIColor) -> (Double, Double, Double) {
        let (r, g, b, _) = channels(color)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low, l = (high + low) / 2
        guard delta != 0 else { return (0, 0, l) }
        let hue = high == r ? ((g - b) / delta).truncatingRemainder(dividingBy: 6) : high == g ? (b - r) / delta + 2 : (r - g) / delta + 4
        return (((hue / 6) + 1).truncatingRemainder(dividingBy: 1), delta / (1 - abs(2 * l - 1)), l)
    }
    private func hslColor(_ color: UIColor, lightness: Double? = nil, saturationFactor: Double = 1) -> UIColor {
        let (h, saturation, originalL) = hsl(color), s = saturation * saturationFactor, l = lightness ?? originalL
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let rgb: (Double, Double, Double)
        switch Int(h * 6) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        func rounded(_ value: Double) -> Double { ((value + m) * 255).rounded() / 255 }
        return UIColor(red: rounded(rgb.0), green: rounded(rgb.1), blue: rounded(rgb.2), alpha: 1)
    }
}
