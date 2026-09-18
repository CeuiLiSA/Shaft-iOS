import SwiftUI
import UIKit

struct DiscoverSocialCopy {
    let tag: String
    private static let catalog: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "discover-social-strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return value
    }()
    func text(_ key: String) -> String { Self.catalog[tag]?[key] ?? Self.catalog["en"]?[key] ?? key }
}

/// Native labels and controls preserve Android's explicit card measurement rules.
/// The entire card, including its arrow, is one accessible navigation action.
struct DiscoverSocialSection: UIViewRepresentable {
    var onChat: () -> Void
    var onCommunity: () -> Void
    var accent: UInt32 = 0x686BDD
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var fontScale: CGFloat = 1

    func makeUIView(context: Context) -> DiscoverSocialSectionView { DiscoverSocialSectionView() }
    func updateUIView(_ view: DiscoverSocialSectionView, context: Context) {
        view.configure(copy: DiscoverSocialCopy(tag: l10n.activeTag), palette: .init(dark: scheme == .dark, accent: accent),
                       scale: fontScale, rtl: direction == .rightToLeft, reduceMotion: reduceMotion,
                       onChat: onChat, onCommunity: onCommunity)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DiscoverSocialSectionView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.measure(width: width))
    }
}

/// The community entry is wired now; its native destination is a separate port.
struct PlazaEntryPendingView: View {
    @Environment(OnboardingStore.self) private var l10n
    var body: some View {
        let title = DiscoverSocialCopy(tag: l10n.activeTag).text("plaza_title")
        PlaceholderView(title: title, systemImage: "bubble.left.and.bubble.right", subtitle: l10n.t(.stNotAvailable))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("plaza-pending-page")
    }
}

final class DiscoverSocialSectionView: UIView {
    private let eyebrow = SocialLabel(), heading = SocialLabel(), footer = SocialLabel()
    private let spark = SocialGlyphView(spark: true)
    private let chat = SocialEntryControl(chat: true), community = SocialEntryControl(chat: false)
    private var scale: CGFloat = 1
    private var rtl = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        [eyebrow, heading, footer, spark, chat, community].forEach(addSubview)
        heading.isAccessibilityElement = true; heading.accessibilityTraits = .header
        accessibilityElements = [heading, chat, community]
        accessibilityIdentifier = "discover-social-section"
        spark.transform = CGAffineTransform(rotationAngle: 8 * .pi / 180)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(copy: DiscoverSocialCopy, palette: DiscoverSocialPalette, scale: CGFloat, rtl: Bool,
                   reduceMotion: Bool, onChat: @escaping () -> Void, onCommunity: @escaping () -> Void) {
        self.scale = scale; self.rtl = rtl
        eyebrow.configure("SHAFT / CONNECT", size: 10 * scale, weight: 700, color: palette.textAccent, tracking: 0.16, rtl: rtl)
        heading.configure(copy.text("discover_social_title"), size: 20 * scale, weight: 700, color: palette.ink, lineRatio: 1.5, rtl: rtl)
        footer.configure("PIXIV-SHAFT", size: 9 * scale, weight: 500, color: palette.secondary(on: palette.background), tracking: 0.22)
        footer.textAlignment = .center
        spark.color = palette.textAccent; spark.backgroundColor = palette.composite(palette.alpha(0.08), over: palette.card)
        spark.layer.cornerRadius = 15
        chat.configure(copy: copy, palette: palette, scale: scale, rtl: rtl, reduceMotion: reduceMotion, action: onChat)
        community.configure(copy: copy, palette: palette, scale: scale, rtl: rtl, reduceMotion: reduceMotion, action: onCommunity)
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }
    func measure(width: CGFloat, place: Bool = false) -> CGFloat {
        let content = max(0, width - 40), headingWidth = max(0, content - 54)
        let eyebrowH = eyebrow.height(for: headingWidth), headingH = heading.height(for: headingWidth)
        let headerH = max(42, eyebrowH + 4 + headingH)
        var y: CGFloat = 28
        if place {
            let x: CGFloat = rtl ? 74 : 20, textTop = y + (headerH - eyebrowH - 4 - headingH) / 2
            eyebrow.frame = CGRect(x: x, y: textTop, width: headingWidth, height: eyebrowH)
            heading.frame = CGRect(x: x, y: textTop + eyebrowH + 4, width: headingWidth, height: headingH)
            spark.bounds = CGRect(x: 0, y: 0, width: 42, height: 42)
            spark.center = CGPoint(x: rtl ? 41 : width - 41, y: y + headerH / 2)
        }
        y += headerH + 16
        let columns = content >= 332 && scale <= 1.3
        let cardWidth = columns ? (content - 12) / 2 : content
        let horizontal = !columns && content >= 264 && scale <= 1.3
        let chatH = chat.measure(width: cardWidth, horizontal: horizontal)
        let communityH = community.measure(width: cardWidth, horizontal: horizontal)
        if columns {
            let height = max(chatH, communityH)
            if place {
                chat.frame = CGRect(x: rtl ? 20 + cardWidth + 12 : 20, y: y, width: cardWidth, height: height)
                community.frame = CGRect(x: rtl ? 20 : 20 + cardWidth + 12, y: y, width: cardWidth, height: height)
            }
            y += height
        } else {
            if place {
                chat.frame = CGRect(x: 20, y: y, width: cardWidth, height: chatH)
                community.frame = CGRect(x: 20, y: y + chatH + 12, width: cardWidth, height: communityH)
            }
            y += chatH + 12 + communityH
        }
        y += 24
        let footerH = footer.height(for: content)
        if place { footer.frame = CGRect(x: 20, y: y, width: content, height: footerH) }
        return y + footerH + 8
    }
    override func layoutSubviews() { super.layoutSubviews(); _ = measure(width: bounds.width, place: true) }
}

private final class SocialEntryControl: UIControl {
    private let chat: Bool
    private let eyebrow = SocialLabel(), title = SocialLabel(), detail = SocialLabel(), actionLabel = SocialLabel()
    private let art: DiscoverSocialArt
    private let arrow = SocialGlyphView(spark: false)
    private let divider = UIView(), pressedFill = UIView()
    private var action: (() -> Void)?
    private var horizontal = false, rtl = false, reduceMotion = false
    init(chat: Bool) {
        self.chat = chat; art = DiscoverSocialArt(chat: chat)
        super.init(frame: .zero)
        layer.cornerRadius = 22; clipsToBounds = true
        [pressedFill, eyebrow, art, title, detail, divider, actionLabel, arrow].forEach(addSubview)
        pressedFill.isUserInteractionEnabled = false; pressedFill.alpha = 0
        isAccessibilityElement = true; accessibilityTraits = .button
        accessibilityIdentifier = chat ? "discover-chat-entry" : "discover-community-entry"
        addTarget(self, action: #selector(open), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func open() { action?() }
    override func accessibilityActivate() -> Bool { action?(); return true }
    func configure(copy: DiscoverSocialCopy, palette: DiscoverSocialPalette, scale: CGFloat, rtl: Bool,
                   reduceMotion: Bool, action: @escaping () -> Void) {
        self.action = action; self.rtl = rtl; self.reduceMotion = reduceMotion
        let fill = chat ? palette.chat : palette.card, accent = palette.accent(on: fill)
        let name = copy.text(chat ? "chat_drawer_entry" : "discover_community_title")
        let description = copy.text(chat ? "discover_chat_description" : "discover_community_description")
        let operation = copy.text(chat ? "discover_chat_action" : "discover_community_action")
        backgroundColor = fill; layer.borderWidth = chat ? 0 : 1; layer.borderColor = palette.hairline.cgColor
        pressedFill.backgroundColor = palette.alpha(0.20)
        eyebrow.configure(chat ? "CHAT ROOM" : "COMMUNITY", size: 10 * scale, weight: 700, color: accent, tracking: 0.09, rtl: rtl)
        title.configure(name, size: 20 * scale, weight: 700, color: palette.ink, lineRatio: 1.4, rtl: rtl)
        detail.configure(description, size: 12 * scale, weight: 400, color: palette.secondary(on: fill), lineRatio: 1.7, rtl: rtl)
        actionLabel.configure(operation, size: 12 * scale, weight: 600, color: accent, lineRatio: 1.5, rtl: rtl)
        let arrowFill = chat ? palette.primary : palette.composite(palette.alpha(0.20), over: fill)
        arrow.backgroundColor = arrowFill; arrow.layer.cornerRadius = 16
        arrow.color = chat ? palette.onPrimary : palette.accent(on: arrowFill)
        arrow.transform = CGAffineTransform(scaleX: rtl ? -1 : 1, y: 1)
        art.palette = palette; divider.backgroundColor = palette.hairline
        accessibilityLabel = [name, description, operation].joined(separator: "，")
        setNeedsLayout()
    }
    func measure(width: CGFloat, horizontal: Bool) -> CGFloat {
        self.horizontal = horizontal
        let inner = max(0, width - 32), artWidth = horizontal ? min(132, floor(inner * 0.44)) : min(142, inner)
        let textWidth = horizontal ? max(0, inner - artWidth - 12) : inner
        let textH = eyebrow.height(for: textWidth) + (horizontal ? 12 : 4) + title.height(for: textWidth) + 6 + detail.height(for: textWidth) + 26 + max(32, actionLabel.height(for: max(0, textWidth - 40)))
        let artH = floor(artWidth * 140 / 142)
        return 30 + (horizontal ? max(textH, artH) : textH + artH + 4)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        pressedFill.frame = bounds
        let inner = max(0, bounds.width - 32), artWidth = horizontal ? min(132, floor(inner * 0.44)) : min(142, inner)
        let textWidth = horizontal ? max(0, inner - artWidth - 12) : inner
        let x = rtl ? bounds.width - 16 - textWidth : 16, artH = floor(artWidth * 140 / 142)
        var y: CGFloat = 16
        func place(_ label: SocialLabel) {
            let h = label.height(for: textWidth)
            label.frame = CGRect(x: x, y: y, width: textWidth, height: h); y += h
        }
        place(eyebrow)
        if horizontal {
            art.frame = CGRect(x: rtl ? 16 : bounds.width - 16 - artWidth, y: 16 + (bounds.height - 30 - artH) / 2, width: artWidth, height: artH)
            y += 12
        } else {
            y += 4
            art.frame = CGRect(x: 16 + (inner - artWidth) / 2, y: y, width: artWidth, height: artH)
            y += artH + 4
        }
        place(title); y += 6; place(detail)
        let labelWidth = max(0, textWidth - 40), labelH = actionLabel.height(for: labelWidth), actionH = max(32, labelH)
        let actionTop = max(y + 26, bounds.height - 14 - actionH)
        actionLabel.frame = CGRect(x: x + (rtl ? 40 : 0), y: actionTop + (actionH - labelH) / 2, width: labelWidth, height: labelH)
        arrow.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        arrow.center = CGPoint(x: rtl ? x + 16 : x + textWidth - 16, y: actionTop + actionH / 2)
        divider.frame = CGRect(x: x, y: actionTop - 12, width: textWidth, height: max(0.5, 1 / traitCollection.displayScale))
    }
    override var isHighlighted: Bool {
        didSet {
            let changes = {
                self.transform = self.isHighlighted && !self.reduceMotion ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
                self.pressedFill.alpha = self.isHighlighted ? 1 : 0
            }
            if reduceMotion { changes() }
            else { UIView.animate(withDuration: isHighlighted ? 0.12 : 0.20, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) }
        }
    }
}

private final class SocialLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0; isUserInteractionEnabled = false; isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value: String, size: CGFloat, weight: Int, color: UIColor, lineRatio: CGFloat = 1, tracking: CGFloat = 0, rtl: Bool = false) {
        let font = ReferralFonts.ui(size, weight), paragraph = NSMutableParagraphStyle()
        // Android's Noto CJK fallback has a taller ascent/descent than PingFang.
        // Preserve its line box while leaving Chinese glyphs in the system font.
        let cjkRanges = value.rangesOfNonLatinScalars
        let lineBox = max(font.lineHeight, cjkRanges.isEmpty ? 0 : size * 1.43)
        paragraph.minimumLineHeight = lineBox
        paragraph.lineSpacing = max(0, size * lineRatio - lineBox)
        paragraph.alignment = rtl ? .right : .left
        let result = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: color, .kern: size * tracking, .paragraphStyle: paragraph])
        let fallback: UIFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular
        for range in cjkRanges {
            result.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: fallback), range: range)
        }
        attributedText = result; textAlignment = rtl ? .right : .left
    }
    func height(for width: CGFloat) -> CGFloat {
        let height = attributedText?.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height ?? 0
        let pixels = max(1, traitCollection.displayScale)
        return ceil(height * pixels) / pixels
    }
}

private extension String {
    var rangesOfNonLatinScalars: [NSRange] {
        var ranges: [NSRange] = [], offset = 0
        for scalar in unicodeScalars {
            let length = scalar.utf16.count
            if scalar.value >= 0x2E80 { ranges.append(NSRange(location: offset, length: length)) }
            offset += length
        }
        return ranges
    }
}

private final class SocialGlyphView: UIView {
    private let spark: Bool
    var color: UIColor = .black { didSet { setNeedsDisplay() } }
    init(spark: Bool) { self.spark = spark; super.init(frame: .zero); clipsToBounds = true; isUserInteractionEnabled = false; isAccessibilityElement = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let padding: CGFloat = spark ? 10 : 7, scale = (bounds.width - padding * 2) / 24
        ctx.translateBy(x: padding, y: padding); ctx.scaleBy(x: scale, y: scale)
        if spark {
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5); ctx.setLineCap(.round)
            for (a, b) in [(CGPoint(x: 12, y: 2), CGPoint(x: 12, y: 22)), (CGPoint(x: 2, y: 12), CGPoint(x: 22, y: 12)), (CGPoint(x: 5, y: 5), CGPoint(x: 19, y: 19)), (CGPoint(x: 5, y: 19), CGPoint(x: 19, y: 5))] {
                ctx.move(to: a); ctx.addLine(to: b)
            }
            ctx.strokePath()
        } else {
            let points: [(CGFloat, CGFloat)] = [(12,4),(10.59,5.41),(16.17,11),(4,11),(4,13),(16.17,13),(10.59,18.59),(12,20),(20,12)]
            ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for (x,y) in points.dropFirst() { ctx.addLine(to: CGPoint(x: x, y: y)) }
            ctx.closePath(); ctx.setFillColor(color.cgColor); ctx.fillPath()
        }
    }
}
