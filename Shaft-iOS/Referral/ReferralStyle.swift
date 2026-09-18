import SwiftUI
import UIKit

/// Exact page-scoped roles from Android ReferralColors; never changes global Theme.
struct ReferralPalette {
    let dark: Bool
    // Android AppTheme's default colorPrimary; the older iOS Theme.brand differs.
    var accent: UInt32 = 0x686BDD
    private func mode(_ light: UInt32, _ night: UInt32) -> Color { Color(hex: dark ? night : light) }
    var bg: Color { mode(0xF8F7FC, 0x101014) }
    var surface: Color { mode(0xFFFFFF, 0x1B1A20) }
    var surface2: Color { mode(0xF0EEF6, 0x24222B) }
    var surface3: Color { mode(0xE9E5F2, 0x302B3A) }
    var ink: Color { mode(0x262331, 0xF3EFFA) }
    var muted: Color { mode(0x716C80, 0xB0A8BD) }
    var line: Color { mode(0xE7E3EE, 0x34303E) }
    var green: Color { mode(0x386746, 0xB7D8AB) }
    var greenBg: Color { mode(0xE9F1E5, 0x283527) }
    var danger: Color { mode(0xA93443, 0xFFB2B9) }
    var peach: Color { mode(0x965F40, 0xE8B695) }
    var peachBg: Color { mode(0xF9E9E0, 0x423027) }
    var blue: Color { mode(0x516795, 0xB4C7EE) }
    var blueBg: Color { mode(0xE6EDF9, 0x293248) }
    var hero: Color { themed(dark ? 0x282236 : 0xEAE3F7) }
    var tint: Color { themed(dark ? 0x3C2E56 : 0xEAE2FF) }
    var onHero: Color { corrected(mode(0x625B72, 0xB0A8BD), on: hero) }
    var onTint: Color { corrected(themed(dark ? 0xDFD0FF : 0x493478), on: tint) }
    var primary: Color { dark ? themed(0xC5AFFF) : corrected(Color(hex: accent), on: surface) }
    var onPrimary: Color { contrast(.white, primary) >= 4.5 ? .white : corrected(Color(hex: 0x30204E), on: primary) }
    var artMax: Color { themed(0xC5B0EC) }
    var artInk: Color { themed(0x33244E) }

    private func themed(_ hex: UInt32) -> Color {
        var color = hsl(hex)
        color.0 = (color.0 + hsl(accent).0 - hsl(0x6A4BC5).0 + 1).truncatingRemainder(dividingBy: 1)
        let c = (1 - abs(2 * color.2 - 1)) * color.1
        let x = c * (1 - abs((color.0 * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = color.2 - c / 2
        let rgb: (Double, Double, Double)
        switch Int(color.0 * 6) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return Color(red: ((rgb.0 + m) * 255).rounded() / 255, green: ((rgb.1 + m) * 255).rounded() / 255, blue: ((rgb.2 + m) * 255).rounded() / 255)
    }
    private func hsl(_ hex: UInt32) -> (Double, Double, Double) {
        let r = Double((hex >> 16) & 255) / 255, g = Double((hex >> 8) & 255) / 255, b = Double(hex & 255) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low, l = (high + low) / 2
        guard delta != 0 else { return (0, 0, l) }
        let hue = high == r ? ((g - b) / delta).truncatingRemainder(dividingBy: 6) : high == g ? (b - r) / delta + 2 : (r - g) / delta + 4
        return (((hue / 6) + 1).truncatingRemainder(dividingBy: 1), delta / (1 - abs(2 * l - 1)), l)
    }
    private func channels(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)]
    }
    private func luminance(_ color: Color) -> Double {
        zip(channels(color), [0.2126, 0.7152, 0.0722]).reduce(0) {
            $0 + ($1.0 < 0.04045 ? $1.0 / 12.92 : pow(($1.0 + 0.055) / 1.055, 2.4)) * $1.1
        }
    }
    private func contrast(_ a: Color, _ b: Color) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    private func corrected(_ foreground: Color, on background: Color) -> Color {
        if contrast(foreground, background) >= 4.5 { return foreground }
        let target = luminance(background) < 0.4 ? 1.0 : 0.0, rgb = channels(foreground)
        for step in 1...100 {
            let fraction = Double(step) / 100
            let c = rgb.map { floor(($0 * (1 - fraction) + target * fraction) * 255) / 255 }
            let value = Color(red: c[0], green: c[1], blue: c[2])
            if contrast(value, background) >= 4.5 { return value }
        }
        return target == 1 ? .white : .black
    }
}

enum ReferralFonts {
    static func name(_ weight: Int) -> String {
        "Montserrat-" + ([400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold", 800: "ExtraBold"][weight] ?? "Regular")
    }
    static func ui(_ size: CGFloat, _ weight: Int) -> UIFont {
        UIFont(name: name(weight), size: size) ?? .systemFont(ofSize: size)
    }
}

/// Montserrat uses the actual bundled weight. CJK keeps the system's weighted fallback.
struct ReferralText: View {
    let value: String
    var size: CGFloat = 14
    var weight: Int = 400
    var color: Color
    var lineMultiple: CGFloat = 1.3
    var tracking: CGFloat = 0
    var lineHeight: CGFloat?
    var headingStar = false
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    var body: some View {
        decoratedText
            .foregroundStyle(color)
            .tracking(tracking * scale)
            .lineSpacing(lineHeight.map { max(0, $0 * scale - ReferralFonts.ui(size * scale, weight).lineHeight) }
                         ?? ReferralFonts.ui(size * scale, weight).lineHeight * (lineMultiple - 1))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(value)
    }
    private var decoratedText: Text {
        let text = Text(attributed)
        guard headingStar else { return text }
        // Inline vector attachment wraps with the last title line. U+2733 is an
        // emoji on iOS even with some fallback-font / variation-selector pairs.
        let side = size * scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { renderer in
            let ctx = renderer.cgContext, radius = side / 2 - 2 * scale
            ctx.setStrokeColor(UIColor.black.cgColor); ctx.setLineWidth(2.2 * scale)
            for index in 0..<4 {
                let angle = CGFloat(index) * .pi / 4
                ctx.move(to: CGPoint(x: side / 2 - cos(angle) * radius, y: side / 2 - sin(angle) * radius))
                ctx.addLine(to: CGPoint(x: side / 2 + cos(angle) * radius, y: side / 2 + sin(angle) * radius))
            }
            ctx.strokePath()
        }
        return text + Text(" ") + Text(Image(uiImage: image).renderingMode(.template)).baselineOffset(-2 * scale)
    }
    private var attributed: AttributedString {
        let string = NSMutableAttributedString(string: value, attributes: [.font: ReferralFonts.ui(size * scale, weight)])
        let fallback: UIFont.Weight = [400: .regular, 500: .medium, 600: .semibold, 700: .bold, 800: .heavy][weight] ?? .regular
        let regex = try! NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}，。；：！？、（）「」《》…✳✧]+"#)
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            string.addAttribute(.font, value: UIFont.systemFont(ofSize: size * scale, weight: fallback), range: match.range)
        }
        return AttributedString(string)
    }
}

/// Cooperates with the app's shared swipe-back delegate while a custom sheet is up.
struct ReferralDismissalGuard: UIViewControllerRepresentable {
    var blocked: Bool
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) { probe.apply(blocked) }
    static func dismantleUIViewController(_ probe: Probe, coordinator: ()) { probe.owner?.isModalInPresentation = false }
    final class Probe: UIViewController {
        weak var owner: UIViewController?
        func apply(_ blocked: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.owner = self.navigationController?.topViewController
                self.owner?.isModalInPresentation = blocked
            }
        }
        override func viewDidLoad() { super.viewDidLoad(); view.isUserInteractionEnabled = false; view.backgroundColor = .clear }
    }
}

struct ReferralPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.12 : 0.2), value: configuration.isPressed)
    }
}

struct ReferralButton: View {
    let label: String
    let palette: ReferralPalette
    var primary = false
    var outline = false
    var icon: ReferralGlyph?
    var expand = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ReferralText(value: label, size: 12, weight: 600, color: primary ? palette.onPrimary : palette.onTint)
                    .multilineTextAlignment(.center)
                if let icon { ReferralIcon(glyph: icon).stroke(primary ? palette.onPrimary : palette.onTint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)).frame(width: 16, height: 16) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: 48)
            .background(primary ? palette.primary : outline ? .clear : palette.tint, in: Capsule())
            .overlay { if outline { Capsule().strokeBorder(palette.line, lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(ReferralPressStyle())
    }
}

struct ReferralIconButton: View {
    var glyph: ReferralGlyph
    var label: String
    var palette: ReferralPalette
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ReferralIcon(glyph: glyph).stroke(palette.ink, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20).frame(width: 48, height: 48).contentShape(Circle())
        }.buttonStyle(ReferralPressStyle()).accessibilityLabel(label)
    }
}

extension View {
    func referralCard(_ palette: ReferralPalette, horizontal: CGFloat = 16, vertical: CGFloat = 18) -> some View {
        padding(.horizontal, horizontal).padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .circular).strokeBorder(palette.line, lineWidth: 1))
    }
}

/// The 428 × 370 Android canvas, including baselines, ticket cuts and rotations.
struct ReferralHeroArt: UIViewRepresentable {
    var palette: ReferralPalette
    var copy: ReferralCopy
    func makeUIView(context: Context) -> ReferralArtCanvas { ReferralArtCanvas() }
    func updateUIView(_ view: ReferralArtCanvas, context: Context) {
        view.palette = palette; view.copy = copy; view.setNeedsDisplay()
    }
}

final class ReferralArtCanvas: UIView {
    var palette = ReferralPalette(dark: false)
    var copy = ReferralCopy(tag: "zh-Hans")
    init() { super.init(frame: .zero); backgroundColor = .clear; isAccessibilityElement = false; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = min(bounds.width / 428, bounds.height / 370)
        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - 428 * scale) / 2, y: (bounds.height - 370 * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        orbit(ctx, CGRect(x: 14, y: 64, width: 394, height: 245), -12)
        orbit(ctx, CGRect(x: 30, y: 75, width: 360, height: 225), 15)
        star(ctx, x: 386, y: 29, radius: 18, color: UIColor(palette.onTint), rays: 6)
        ticket(ctx, x: 24, y: 24, angle: -8, max: false)
        ticket(ctx, x: 178, y: 76, angle: 8, max: true)
        ctx.restoreGState()
    }
    private func orbit(_ ctx: CGContext, _ rect: CGRect, _ angle: CGFloat) {
        ctx.saveGState(); rotate(ctx, angle, rect.midX, rect.midY)
        ctx.setStrokeColor(UIColor(palette.primary).withAlphaComponent(30 / 255).cgColor)
        ctx.setLineWidth(1); ctx.strokeEllipse(in: rect); ctx.restoreGState()
    }
    private func rotate(_ ctx: CGContext, _ angle: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        ctx.translateBy(x: x, y: y); ctx.rotate(by: angle * .pi / 180); ctx.translateBy(x: -x, y: -y)
    }
    private func ticket(_ ctx: CGContext, x: CGFloat, y: CGFloat, angle: CGFloat, max: Bool) {
        ctx.saveGState(); ctx.translateBy(x: x, y: y); rotate(ctx, angle, 107, 132)
        for i in stride(from: 5, through: 1, by: -1) {
            UIColor(red: 50 / 255, green: 37 / 255, blue: 82 / 255, alpha: 3 / 255).setFill()
            UIBezierPath(roundedRect: CGRect(x: -i, y: 4, width: 214 + 2 * i, height: 266 + i), cornerRadius: 18).fill()
        }
        UIColor(max ? palette.artMax : Color(hex: 0xFCFBF4)).setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 214, height: 264), cornerRadius: 18).fill()
        let ink = UIColor(max ? palette.artInk : Color(hex: 0x423650))
        text("EXPERIENCE PASS", 21, 34, 7, 600, ink)
        star(ctx, x: 183, y: 29, radius: 8, color: ink, rays: 4)
        text(max ? "MAX" : "PRO", 21, 114, 56, 800, ink)
        text("P A S S", 22, 132, 11, 500, ink)
        ctx.setStrokeColor(ink.withAlphaComponent(65 / 255).cgColor); ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3]); ctx.move(to: CGPoint(x: 0, y: 182)); ctx.addLine(to: CGPoint(x: 214, y: 182)); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(UIColor(palette.hero).cgColor)
        for x in [CGFloat(0), 214] { ctx.fillEllipse(in: CGRect(x: x - 8, y: 174, width: 16, height: 16)) }
        text("7", 21, 232, 39, 500, ink)
        text(copy.text("day_unit"), 48, 231, 12, 400, ink)
        text(copy.text("week_caption"), 104, 211, 8, 400, ink)
        text("7-DAY ACCESS", 104, 224, 6.7, 400, ink)
        ctx.restoreGState()
    }
    private func text(_ value: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat, _ weight: Int, _ color: UIColor) {
        let font = ReferralFonts.ui(size, weight)
        (value as NSString).draw(at: CGPoint(x: x, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: color])
    }
    private func star(_ ctx: CGContext, x: CGFloat, y: CGFloat, radius: CGFloat, color: UIColor, rays: Int) {
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1)
        if rays == 4 {
            let points: [(CGFloat, CGFloat)] = [(0,-1),(0.3,-0.3),(1,0),(0.3,0.3),(0,1),(-0.3,0.3),(-1,0),(-0.3,-0.3)]
            for (i, p) in points.enumerated() {
                let point = CGPoint(x: x + p.0 * radius, y: y + p.1 * radius)
                if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
            }
            ctx.closePath()
        } else {
            for i in 0..<rays {
                let angle = CGFloat.pi * CGFloat(i) / CGFloat(rays)
                ctx.move(to: CGPoint(x: x - cos(angle) * radius, y: y - sin(angle) * radius))
                ctx.addLine(to: CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius))
            }
        }
        ctx.strokePath()
    }
}
