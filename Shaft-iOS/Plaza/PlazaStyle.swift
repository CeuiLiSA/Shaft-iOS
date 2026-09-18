import SwiftUI

/// Current Android AppTheme (#686BDD) and the corresponding V3Palette ramp.
/// Kept local to this port so the existing iOS global palette is not rewritten.
enum PlazaPalette {
    static let primary = Color(hex: 0x686BDD)
    static let card = Color(light: 0xF2F2F8, dark: 0x1F1F26)
    static let hairline = Color(light: 0x2529A7, dark: 0x686BDD, lightAlpha: 0.12, darkAlpha: 0.12)
    static let accent = Color(light: 0x2529A7, dark: 0x8183E3)
}

/// Android dp/sp map to iOS points at the default size; Dynamic Type scales text.
struct PlazaText: View {
    let value: String
    var size: CGFloat = 14
    var weight: Int = 400
    var color: Color = Theme.v3Text1
    var lineHeight: CGFloat?
    @ScaledMetric private var scale: CGFloat = 1
    var body: some View {
        Text(attributed)
            .foregroundStyle(color)
            .lineSpacing(max(0, (lineHeight ?? size * 1.2) * scale - font.lineHeight))
            .multilineTextAlignment(.leading)
    }
    private var font: UIFont { UIFont(name: "Montserrat-" + ([400:"Regular",500:"Medium",600:"SemiBold",700:"Bold",800:"ExtraBold"][weight] ?? "Regular"), size: size * scale) ?? .systemFont(ofSize: size * scale) }
    private var attributed: AttributedString {
        let text = NSMutableAttributedString(string: value, attributes: [.font: font])
        let w: UIFont.Weight = [400:.regular,500:.medium,600:.semibold,700:.bold,800:.heavy][weight] ?? .regular
        let pattern = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}，。；：！？、（）「」《》]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length)) {
                text.addAttribute(.font, value: UIFont.systemFont(ofSize: size * scale, weight: w), range: match.range)
            }
        }
        return (try? AttributedString(text, including: \.uiKit)) ?? AttributedString(value)
    }
}

struct PlazaPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct PlazaToolbar<Center: View, Trailing: View>: View {
    var back: () -> Void
    var backID = "plaza-back"
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailing: () -> Trailing
    @Environment(OnboardingStore.self) private var language
    var body: some View {
        ZStack {
            center().padding(.horizontal, 64)
            HStack(spacing: 0) {
                Button(action: back) {
                    Image("plaza-back").resizable().scaledToFit().frame(width: 24, height: 24)
                        .frame(width: 56, height: 56).contentShape(Rectangle())
                }.accessibilityLabel(PlazaCopy(tag: language.activeTag).text("back"))
                    .accessibilityIdentifier(backID)
                Spacer(minLength: 0)
                trailing().padding(.trailing, 4)
            }
        }
        .frame(minHeight: 56)
        .foregroundStyle(.white)
        .background(PlazaPalette.primary.ignoresSafeArea(edges: .top))
        .buttonStyle(PlazaPressStyle())
    }
}

struct PlazaPill: View {
    var glyph: PlazaGlyph?
    var emoji: String?
    var count: Int?
    var selected = false
    var label: String
    var action: () -> Void
    @ScaledMetric private var height: CGFloat = 32
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let glyph { PlazaIcon(glyph: glyph, size: 20).foregroundStyle(glyph == .heartFilled ? Theme.v3Pink : selected ? PlazaPalette.accent : Theme.v3Text2) }
                if let emoji { Text(emoji).font(.system(size: 18)) }
                if let count, count > 0 { PlazaText(value: String(count), size: 14, weight: 600, color: selected ? PlazaPalette.accent : Theme.v3Text2).monospacedDigit() }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: height)
            .foregroundStyle(selected ? PlazaPalette.accent : Theme.v3Text2)
            .background(PlazaPalette.primary.opacity(selected ? 0.20 : 0.08), in: Capsule())
            .overlay { if selected { Capsule().strokeBorder(PlazaPalette.primary.opacity(0.3), lineWidth: 0.5) } }
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlazaPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(count.map(String.init) ?? "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct PlazaStateView: View {
    var text: String
    var error = false
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 8) {
            if error {
                PlazaIcon(glyph: .error, size: 120).foregroundStyle(PlazaPalette.accent.opacity(0.6))
            } else {
                Image("plaza-empty").resizable().scaledToFit().frame(width: 120, height: 120)
                    .foregroundStyle(PlazaPalette.accent.opacity(0.6))
            }
            PlazaText(value: text, size: 14, color: Theme.v3Text2)
                .multilineTextAlignment(.center).padding(.horizontal, 16)
            if let actionTitle, let action {
                Button(action: action) {
                    PlazaText(value: actionTitle, weight: 600, color: .white)
                        .padding(.horizontal, 20).frame(minHeight: 48)
                        .background(PlazaPalette.primary, in: Capsule())
                }.buttonStyle(PlazaPressStyle()).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity, minHeight: 320)
    }
}

struct PlazaSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3) { index in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Circle().frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 9) {
                            RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 14)
                            RoundedRectangle(cornerRadius: 4).frame(width: 72, height: 11)
                        }
                    }
                    RoundedRectangle(cornerRadius: 4).frame(height: 14)
                    RoundedRectangle(cornerRadius: 4).frame(width: 210, height: 14)
                    if index % 2 == 0 { RoundedRectangle(cornerRadius: 16).aspectRatio(16 / 9, contentMode: .fit) }
                    HStack(spacing: 8) { ForEach(0..<3) { _ in Capsule().frame(width: 56, height: 32) } }
                }.padding(16)
                Divider()
            }
        }.foregroundStyle(Theme.v3Surface2).redacted(reason: .placeholder).accessibilityHidden(true)
    }
}

struct PlazaSectionLabel: View {
    var text: String
    var body: some View {
        PlazaText(value: text.uppercased(), size: 12, weight: 700, color: Theme.v3Text3)
            .tracking(1.44).accessibilityAddTraits(.isHeader)
    }
}

/// Flexbox: four points between chips and no extra gap between 48-point rows.
struct PlazaReactionLayout: Layout {
    private func positions(width: CGFloat, subviews: Subviews) -> (CGSize, [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + 4; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 720, subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = positions(width: bounds.width, subviews: subviews).1
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y),
                       proposal: ProposedViewSize(view.sizeThatFits(.unspecified)))
        }
    }
}

extension View {
    func plazaCard() -> some View {
        self.padding(.horizontal, 16).padding(.vertical, 14)
            .background(PlazaPalette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(PlazaPalette.hairline, lineWidth: 0.5) }
    }
    func plazaScreen() -> some View {
        self.background(Theme.v3Bg).toolbar(.hidden, for: .navigationBar, .tabBar)
            .background(SwipeBackEnabler()).tint(PlazaPalette.accent)
    }
}
