// Generated from Android ReferralIcon. Run scripts/sync-referral-assets.py.
import SwiftUI

enum ReferralGlyph {
    case arrow, back, user, stack, play, heart, ticket, moon, check, close, copy
    var path: Path {
        var p = Path()
        switch self {
        case .arrow:
            p.move(to: CGPoint(x: 5, y: 12))
            p.addLine(to: CGPoint(x: 19, y: 12))
            p.move(to: CGPoint(x: 13, y: 6))
            p.addLine(to: CGPoint(x: 19, y: 12))
            p.addLine(to: CGPoint(x: 13, y: 18))
        case .back:
            p.move(to: CGPoint(x: 19, y: 12))
            p.addLine(to: CGPoint(x: 5, y: 12))
            p.move(to: CGPoint(x: 11, y: 6))
            p.addLine(to: CGPoint(x: 5, y: 12))
            p.addLine(to: CGPoint(x: 11, y: 18))
        case .user:
            p.move(to: CGPoint(x: 12, y: 8))
            p.addCurve(to: CGPoint(x: 9, y: 11), control1: CGPoint(x: 12, y: 9.65685425), control2: CGPoint(x: 10.6568542, y: 11))
            p.addCurve(to: CGPoint(x: 6, y: 8), control1: CGPoint(x: 7.34314575, y: 11), control2: CGPoint(x: 6, y: 9.65685425))
            p.addCurve(to: CGPoint(x: 9, y: 5), control1: CGPoint(x: 6, y: 6.34314575), control2: CGPoint(x: 7.34314575, y: 5))
            p.addCurve(to: CGPoint(x: 12, y: 8), control1: CGPoint(x: 10.6568542, y: 5), control2: CGPoint(x: 12, y: 6.34314575))
            p.move(to: CGPoint(x: 3, y: 20))
            p.addLine(to: CGPoint(x: 3, y: 18))
            p.addCurve(to: CGPoint(x: 9, y: 12), control1: CGPoint(x: 3, y: 14.6862915), control2: CGPoint(x: 5.6862915, y: 12))
            p.addCurve(to: CGPoint(x: 15, y: 18), control1: CGPoint(x: 12.3137085, y: 12), control2: CGPoint(x: 15, y: 14.6862915))
            p.addLine(to: CGPoint(x: 15, y: 20))
            p.move(to: CGPoint(x: 19, y: 7))
            p.addLine(to: CGPoint(x: 19, y: 13))
            p.move(to: CGPoint(x: 16, y: 10))
            p.addLine(to: CGPoint(x: 22, y: 10))
        case .stack:
            p.move(to: CGPoint(x: 10, y: 3))
            p.addLine(to: CGPoint(x: 17, y: 3))
            p.addQuadCurve(to: CGPoint(x: 20, y: 6), control: CGPoint(x: 20, y: 3))
            p.addLine(to: CGPoint(x: 20, y: 15))
            p.addQuadCurve(to: CGPoint(x: 17, y: 18), control: CGPoint(x: 20, y: 18))
            p.addLine(to: CGPoint(x: 10, y: 18))
            p.addQuadCurve(to: CGPoint(x: 7, y: 15), control: CGPoint(x: 7, y: 18))
            p.addLine(to: CGPoint(x: 7, y: 6))
            p.addQuadCurve(to: CGPoint(x: 10, y: 3), control: CGPoint(x: 7, y: 3))
            p.move(to: CGPoint(x: 16, y: 21))
            p.addLine(to: CGPoint(x: 6, y: 21))
            p.addQuadCurve(to: CGPoint(x: 3, y: 18), control: CGPoint(x: 3, y: 21))
            p.addLine(to: CGPoint(x: 3, y: 8))
            p.move(to: CGPoint(x: 10, y: 13))
            p.addLine(to: CGPoint(x: 13, y: 10))
            p.addLine(to: CGPoint(x: 17, y: 14))
        case .play:
            p.move(to: CGPoint(x: 7, y: 4))
            p.addLine(to: CGPoint(x: 17, y: 4))
            p.addQuadCurve(to: CGPoint(x: 21, y: 8), control: CGPoint(x: 21, y: 4))
            p.addLine(to: CGPoint(x: 21, y: 16))
            p.addQuadCurve(to: CGPoint(x: 17, y: 20), control: CGPoint(x: 21, y: 20))
            p.addLine(to: CGPoint(x: 7, y: 20))
            p.addQuadCurve(to: CGPoint(x: 3, y: 16), control: CGPoint(x: 3, y: 20))
            p.addLine(to: CGPoint(x: 3, y: 8))
            p.addQuadCurve(to: CGPoint(x: 7, y: 4), control: CGPoint(x: 3, y: 4))
            p.move(to: CGPoint(x: 10, y: 9))
            p.addLine(to: CGPoint(x: 15, y: 12))
            p.addLine(to: CGPoint(x: 10, y: 15))
            p.addLine(to: CGPoint(x: 10, y: 9))
            p.closeSubpath()
        case .heart:
            p.move(to: CGPoint(x: 20.8, y: 4.6))
            p.addCurve(to: CGPoint(x: 13, y: 4.6), control1: CGPoint(x: 18.6, y: 2.5), control2: CGPoint(x: 15.2, y: 2.5))
            p.addLine(to: CGPoint(x: 12, y: 5.7))
            p.addLine(to: CGPoint(x: 10.9, y: 4.6))
            p.addCurve(to: CGPoint(x: 3.1, y: 4.6), control1: CGPoint(x: 8.7, y: 2.5), control2: CGPoint(x: 5.3, y: 2.5))
            p.addCurve(to: CGPoint(x: 3.1, y: 12.4), control1: CGPoint(x: 1, y: 6.8), control2: CGPoint(x: 1, y: 10.2))
            p.addLine(to: CGPoint(x: 12, y: 21))
            p.addLine(to: CGPoint(x: 20.8, y: 12.4))
            p.addCurve(to: CGPoint(x: 20.8, y: 4.6), control1: CGPoint(x: 23, y: 10.2), control2: CGPoint(x: 23, y: 6.8))
            p.closeSubpath()
        case .ticket:
            p.move(to: CGPoint(x: 3, y: 5))
            p.addLine(to: CGPoint(x: 21, y: 5))
            p.addLine(to: CGPoint(x: 21, y: 10))
            p.addCurve(to: CGPoint(x: 19, y: 12), control1: CGPoint(x: 19.8954305, y: 10), control2: CGPoint(x: 19, y: 10.8954305))
            p.addCurve(to: CGPoint(x: 21, y: 14), control1: CGPoint(x: 19, y: 13.1045695), control2: CGPoint(x: 19.8954305, y: 14))
            p.addLine(to: CGPoint(x: 21, y: 19))
            p.addLine(to: CGPoint(x: 3, y: 19))
            p.addLine(to: CGPoint(x: 3, y: 14))
            p.addCurve(to: CGPoint(x: 5, y: 12), control1: CGPoint(x: 4.1045695, y: 14), control2: CGPoint(x: 5, y: 13.1045695))
            p.addCurve(to: CGPoint(x: 3, y: 10), control1: CGPoint(x: 5, y: 10.8954305), control2: CGPoint(x: 4.1045695, y: 10))
            p.addLine(to: CGPoint(x: 3, y: 5))
            p.closeSubpath()
            p.move(to: CGPoint(x: 15, y: 5))
            p.addLine(to: CGPoint(x: 15, y: 8))
            p.move(to: CGPoint(x: 15, y: 11))
            p.addLine(to: CGPoint(x: 15, y: 13))
            p.move(to: CGPoint(x: 15, y: 16))
            p.addLine(to: CGPoint(x: 15, y: 19))
        case .moon:
            p.move(to: CGPoint(x: 20.6, y: 14))
            p.addCurve(to: CGPoint(x: 12.458822, y: 11.541178), control1: CGPoint(x: 17.6457622, y: 14.5950868), control2: CGPoint(x: 14.589743, y: 13.6720991))
            p.addCurve(to: CGPoint(x: 10, y: 3.4), control1: CGPoint(x: 10.3279009, y: 9.41025697), control2: CGPoint(x: 9.4049132, y: 6.35423779))
            p.addCurve(to: CGPoint(x: 2.79696552, y: 12.8186716), control1: CGPoint(x: 5.57788093, y: 4.29076941), control2: CGPoint(x: 2.49829667, y: 8.31762685))
            p.addCurve(to: CGPoint(x: 11.1813284, y: 21.2030345), control1: CGPoint(x: 3.09563438, y: 17.3197164), control2: CGPoint(x: 6.6802836, y: 20.9043656))
            p.addCurve(to: CGPoint(x: 20.6, y: 14), control1: CGPoint(x: 15.6823732, y: 21.5017033), control2: CGPoint(x: 19.7092306, y: 18.4221191))
            p.closeSubpath()
        case .check:
            p.move(to: CGPoint(x: 5, y: 12))
            p.addLine(to: CGPoint(x: 9, y: 16))
            p.addLine(to: CGPoint(x: 19, y: 6))
        case .close:
            p.move(to: CGPoint(x: 6, y: 6))
            p.addLine(to: CGPoint(x: 18, y: 18))
            p.move(to: CGPoint(x: 6, y: 18))
            p.addLine(to: CGPoint(x: 18, y: 6))
        case .copy:
            p.move(to: CGPoint(x: 10, y: 8))
            p.addLine(to: CGPoint(x: 18, y: 8))
            p.addQuadCurve(to: CGPoint(x: 20, y: 10), control: CGPoint(x: 20, y: 8))
            p.addLine(to: CGPoint(x: 20, y: 19))
            p.addQuadCurve(to: CGPoint(x: 18, y: 21), control: CGPoint(x: 20, y: 21))
            p.addLine(to: CGPoint(x: 10, y: 21))
            p.addQuadCurve(to: CGPoint(x: 8, y: 19), control: CGPoint(x: 8, y: 21))
            p.addLine(to: CGPoint(x: 8, y: 10))
            p.addQuadCurve(to: CGPoint(x: 10, y: 8), control: CGPoint(x: 8, y: 8))
            p.move(to: CGPoint(x: 16, y: 8))
            p.addLine(to: CGPoint(x: 16, y: 5))
            p.addQuadCurve(to: CGPoint(x: 14, y: 3), control: CGPoint(x: 16, y: 3))
            p.addLine(to: CGPoint(x: 5, y: 3))
            p.addQuadCurve(to: CGPoint(x: 3, y: 5), control: CGPoint(x: 3, y: 3))
            p.addLine(to: CGPoint(x: 3, y: 14))
            p.addQuadCurve(to: CGPoint(x: 5, y: 16), control: CGPoint(x: 3, y: 16))
            p.addLine(to: CGPoint(x: 8, y: 16))
        }
        return p
    }
}

struct ReferralIcon {
    var glyph: ReferralGlyph
    func stroke(_ color: Color, lineWidth: CGFloat) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
    func stroke(_ color: Color, style: StrokeStyle) -> some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            context.stroke(glyph.path, with: .color(color), style: style)
        }.accessibilityHidden(true)
    }
}
