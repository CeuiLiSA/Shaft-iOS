import UIKit

/// The original 142 × 140 Android canvas, with identical paths and rotations.
final class DiscoverSocialArt: UIView {
    var palette = DiscoverSocialPalette(dark: false) { didSet { setNeedsDisplay() } }
    let chat: Bool
    init(chat: Bool) {
        self.chat = chat
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = min(bounds.width / 142, bounds.height / 140)
        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - 142 * scale) / 2, y: (bounds.height - 140 * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        rotated(ctx, -25, 71, 72) {
            ctx.setStrokeColor(palette.alpha(0.15).cgColor); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: 5, y: 24, width: 132, height: 96))
        }
        ctx.setStrokeColor(palette.alpha(0.08).cgColor); ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: 12, y: 13, width: 118, height: 118))
        if chat { drawChat(ctx) } else { drawCommunity(ctx) }
        ctx.restoreGState()
    }
    private func drawChat(_ ctx: CGContext) {
        rotated(ctx, -12, 52.5, 51) {
            let bubble = rounded(9, 21, 96, 81, 19, bottomLeft: 5)
            shadow(ctx, bubble); fill(ctx, bubble, palette.card)
            let ink = palette.composite(palette.alpha(0.30), over: palette.card)
            fill(ctx, rounded(28, 42, 71, 47, 3), ink)
            fill(ctx, rounded(28, 54, 57, 59, 3), ink)
        }
        rotated(ctx, 9, 84.5, 90) {
            let bubble = rounded(40, 59, 129, 121, 20, bottomRight: 5)
            shadow(ctx, bubble); fill(ctx, bubble, palette.primary)
            for x: CGFloat in [67, 84.5, 102] { circle(ctx, x, 90, 4, palette.onPrimary) }
        }
        spark(ctx, 129, 28, 11)
        circle(ctx, 15, 121, 2.5, palette.alpha(0.50))
    }
    private func drawCommunity(_ ctx: CGContext) {
        rotated(ctx, -15, 53.5, 70.5) {
            let card = rounded(16, 25, 91, 116, 13)
            fill(ctx, card, palette.composite(palette.alpha(0.20), over: palette.card))
            stroke(ctx, card, palette.alpha(0.15), 1)
            fill(ctx, rounded(27, 40, 53, 44, 2), palette.alpha(0.50))
            fill(ctx, rounded(27, 51, 45, 55, 2), palette.alpha(0.50))
        }
        rotated(ctx, 10, 83.5, 67.5) {
            fill(ctx, rounded(47, 26, 122, 117, 13), palette.alpha(0.08))
            let card = rounded(46, 22, 121, 113, 13)
            fill(ctx, card, palette.card); stroke(ctx, card, palette.hairline, 1)
            let image = rounded(53, 29, 114, 76, 7)
            fill(ctx, image, palette.composite(palette.alpha(0.20), over: palette.card))
            ctx.saveGState(); ctx.addPath(image); ctx.clip()
            let hill = CGMutablePath()
            hill.move(to: CGPoint(x: 46, y: 76)); hill.addCurve(to: CGPoint(x: 96, y: 76), control1: CGPoint(x: 54, y: 47), control2: CGPoint(x: 81, y: 52)); hill.closeSubpath()
            fill(ctx, hill, palette.composite(palette.alpha(0.60), over: palette.card))
            let front = CGMutablePath()
            front.move(to: CGPoint(x: 78, y: 76)); front.addCurve(to: CGPoint(x: 122, y: 61), control1: CGPoint(x: 86, y: 46), control2: CGPoint(x: 109, y: 51)); front.addLine(to: CGPoint(x: 122, y: 76)); front.closeSubpath()
            fill(ctx, front, palette.primary); ctx.restoreGState()
            spark(ctx, 101, 44, 8)
            let line = palette.composite(palette.alpha(0.15), over: palette.card)
            fill(ctx, rounded(53, 84, 93, 88, 2), line)
            fill(ctx, rounded(53, 93, 79, 97, 2), line)
        }
        rotated(ctx, -12, 34.5, 106) {
            let seal = rounded(15, 88, 54, 124, 13, bottomLeft: 5)
            fill(ctx, seal, palette.primary); stroke(ctx, seal, palette.card, 3)
            ctx.saveGState(); ctx.translateBy(x: 24, y: 96); ctx.scaleBy(x: 0.85, y: 0.85)
            let heart = CGMutablePath()
            heart.move(to: CGPoint(x: 12, y: 21))
            heart.addCurve(to: CGPoint(x: 2, y: 8), control1: CGPoint(x: 8, y: 17), control2: CGPoint(x: 2, y: 13))
            heart.addCurve(to: CGPoint(x: 12, y: 6), control1: CGPoint(x: 2, y: 2), control2: CGPoint(x: 9, y: 1))
            heart.addCurve(to: CGPoint(x: 22, y: 8), control1: CGPoint(x: 15, y: 1), control2: CGPoint(x: 22, y: 2))
            heart.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 22, y: 13), control2: CGPoint(x: 16, y: 17))
            heart.closeSubpath(); fill(ctx, heart, palette.onPrimary); ctx.restoreGState()
        }
        circle(ctx, 134, 28, 2.5, palette.alpha(0.50))
    }
    private func shadow(_ ctx: CGContext, _ path: CGPath) {
        ctx.saveGState(); ctx.translateBy(x: 0, y: 3); fill(ctx, path, palette.alpha(0.08)); ctx.restoreGState()
    }
    private func rotated(_ ctx: CGContext, _ angle: CGFloat, _ x: CGFloat, _ y: CGFloat, _ draw: () -> Void) {
        ctx.saveGState(); ctx.translateBy(x: x, y: y); ctx.rotate(by: angle * .pi / 180); ctx.translateBy(x: -x, y: -y)
        draw(); ctx.restoreGState()
    }
    private func circle(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: UIColor) {
        ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
    private func spark(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        let diagonal = radius * 0.70
        ctx.setStrokeColor(palette.textAccent.cgColor); ctx.setLineWidth(1.6)
        for (dx, dy) in [(radius, 0), (0, radius), (diagonal, diagonal), (diagonal, -diagonal)] {
            ctx.move(to: CGPoint(x: x - dx, y: y - dy)); ctx.addLine(to: CGPoint(x: x + dx, y: y + dy))
        }
        ctx.strokePath()
    }
    private func fill(_ ctx: CGContext, _ path: CGPath, _ color: UIColor) { ctx.addPath(path); ctx.setFillColor(color.cgColor); ctx.fillPath() }
    private func stroke(_ ctx: CGContext, _ path: CGPath, _ color: UIColor, _ width: CGFloat) { ctx.addPath(path); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.strokePath() }
    private func rounded(_ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat, _ radius: CGFloat,
                         bottomLeft: CGFloat? = nil, bottomRight: CGFloat? = nil) -> CGPath {
        let radius = min(radius, (right - left) / 2, (bottom - top) / 2)
        let bl = bottomLeft ?? radius, br = bottomRight ?? radius, p = CGMutablePath()
        p.move(to: CGPoint(x: left + radius, y: top))
        p.addLine(to: CGPoint(x: right - radius, y: top))
        p.addArc(center: CGPoint(x: right - radius, y: top + radius), radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: right, y: bottom - br))
        p.addArc(center: CGPoint(x: right - br, y: bottom - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: left + bl, y: bottom))
        p.addArc(center: CGPoint(x: left + bl, y: bottom - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: left, y: top + radius))
        p.addArc(center: CGPoint(x: left + radius, y: top + radius), radius: radius, startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
        p.closeSubpath(); return p
    }
}
