import SwiftUI
import UIKit

/// 1:1 port of `CustomThemeColorSheet` + `ColorPickerViews.kt` (issue #1014):
/// the MD3 colour-picker trio — HSV square + hue bar + HEX field — plus a big
/// rounded preview. Moving any one of the three updates the other two and the
/// preview immediately.
///
/// HSV is the only source of truth (`hue`/`saturation`/`value`), never an RGB
/// int: decoding pure black / white back to HSV collapses the hue to 0, so a
/// user who drags to a corner and back would lose their hue.
///
/// The result goes back through `onConfirm` as `0xRRGGBB`; the sheet only
/// "picks a colour" — saving stays with the caller. Cancel saves nothing.
/// With `textBackground` set (the novel reader's text-colour row, #1142) the
/// preview shows the candidate as text on that reading background.
struct HSVColorPickerSheet: View {
    let title: String
    let textBackground: UIColor?
    let onConfirm: (UInt32) -> Void

    @State private var hue: Double
    @State private var saturation: Double
    @State private var value: Double
    @State private var hexInput: String
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    init(title: String, initialRGB: UInt32, textBackground: UIColor? = nil, onConfirm: @escaping (UInt32) -> Void) {
        self.title = title
        self.textBackground = textBackground
        self.onConfirm = onConfirm
        let hsv = HSV(rgb: initialRGB)
        _hue = State(initialValue: hsv.h)
        _saturation = State(initialValue: hsv.s)
        _value = State(initialValue: hsv.v)
        _hexInput = State(initialValue: HSV.hex(initialRGB))
    }

    private var currentRGB: UInt32 { HSV(h: hue, s: saturation, v: value).rgb }

    var body: some View {
        VStack(spacing: 0) {
            // sheet_title: Montserrat SemiBold 16, centred, paddings 20/16/20/4
            Text(title)
                .font(.montserratSemiBold(16))
                .foregroundStyle(Theme.v3Text1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            // Title and actions on separate rows so long translations / large
            // type never squeeze each other (#1142).
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Text(l10n.t(.actionCancel))
                        .font(.montserratMedium(16))
                        .foregroundStyle(Theme.v3TextAccent)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.leading, 20).padding(.trailing, 12)
                        .contentShape(.rect)
                }
                Button {
                    onConfirm(currentRGB)
                    dismiss()
                } label: {
                    Text(l10n.t(.stSure))
                        .font(.montserratSemiBold(16))
                        .foregroundStyle(Theme.v3TextAccent)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .trailing)
                        .padding(.leading, 12).padding(.trailing, 20)
                        .contentShape(.rect)
                }
            }
            .buttonStyle(.plain)

            ScrollView {
                VStack(spacing: 0) {
                    preview
                    SaturationValueSquare(hue: hue, saturation: $saturation, value: $value)
                        .frame(height: 196)
                        .padding(.top, 16)
                    HueSlider(hue: $hue)
                        .frame(height: 28)
                        .padding(.top, 22)
                        .padding(.bottom, 18)
                    hexCard
                    Text(l10n.t(.customThemeColorHint))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3Text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.v3Bg.ignoresSafeArea())
        .onChange(of: hue) { _, _ in syncHexInput() }
        .onChange(of: saturation) { _, _ in syncHexInput() }
        .onChange(of: value) { _, _ in syncHexInput() }
    }

    // MARK: Preview

    private var preview: some View {
        let rgb = currentRGB
        let hex = HSV.hex(rgb)
        let color = Color(rgb: rgb)
        return Text(textBackground == nil ? hex : "\(title)\n\(hex)")
            .font(.montserratSemiBold(22))
            .tracking(22 * 0.06)
            .multilineTextAlignment(.center)
            .foregroundStyle(textBackground == nil ? HSV.contrastingText(rgb) : color)
            .frame(maxWidth: .infinity, minHeight: 92 - 32)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(textBackground.map { Color($0) } ?? color)
            )
    }

    // MARK: HEX field

    private var hexCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.t(.customThemeColorHexLabel))
                .font(.system(size: 15))
                .foregroundStyle(Theme.v3Text1)
            TextField(l10n.t(.customThemeColorHexHint), text: $hexInput)
                .font(.system(size: 15))
                .foregroundStyle(Theme.v3Text1)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .frame(minHeight: 48)
                .onChange(of: hexInput) { _, text in applyHexInput(text) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.v3MenuBg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.v3Border2, lineWidth: 0.5))
    }

    /// The field's own edits must not be written back into it (cursor jumps).
    private func syncHexInput() {
        let hex = HSV.hex(currentRGB)
        if HSV.normalize(hexInput) != hex { hexInput = hex }
    }

    private func applyHexInput(_ text: String) {
        // `android:digits` + `maxLength=7`.
        let filtered = String(text.filter { "#0123456789ABCDEFabcdef".contains($0) }.prefix(7))
        if filtered != text { hexInput = filtered; return }
        // A half-typed value ("#6", "#68b"…) must not drag the square away —
        // only a complete, valid colour counts.
        guard let normalized = HSV.normalize(text), let rgb = HSV.parse(normalized) else { return }
        guard normalized != HSV.hex(currentRGB) else { return }
        let hsv = HSV(rgb: rgb)
        // A grey (S = 0) decodes to hue 0 and would wipe the hue the user just
        // tuned — keep it.
        if hsv.s > 0 { hue = hsv.h }
        saturation = hsv.s
        value = hsv.v
    }
}

// MARK: - SaturationValueView

/// Saturation (left 0 → right 1) / value (top 1 → bottom 0) square. Three
/// layers — pure hue → horizontal white-to-clear → vertical clear-to-black —
/// under one 20pt corner; white-ringed thumb (r 11, ring 3, 1pt #33000000
/// hairline), pulled inward so the whole ring stays inside the square.
private struct SaturationValueSquare: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var value: Double

    private static let thumbRadius: CGFloat = 11
    private static let thumbRing: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let r = Self.thumbRadius
            let cx = min(max(saturation * size.width, r), size.width - r)
            let cy = min(max((1 - value) * size.height, r), size.height - r)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(rgb: HSV(h: hue, s: 1, v: 1).rgb))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                ZStack {
                    Circle().fill(Color(rgb: HSV(h: hue, s: saturation, v: value).rgb))
                    Circle().inset(by: Self.thumbRing / 2).stroke(.white, lineWidth: Self.thumbRing)
                    Circle().stroke(Color.black.opacity(0x33 / 255), lineWidth: 1)
                }
                .frame(width: r * 2, height: r * 2)
                .position(x: cx, y: cy)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        saturation = min(max(g.location.x / max(size.width, 1), 0), 1)
                        value = min(max(1 - g.location.y / max(size.height, 1), 0), 1)
                    }
            )
        }
    }
}

// MARK: - HueSliderView

/// Fully rounded 13-stop rainbow track, inset by half a handle on each side so
/// the handle never overflows; MD3-E white capsule handle (9pt wide, 4pt
/// overhang above and below, 1pt #33000000 hairline).
private struct HueSlider: View {
    @Binding var hue: Double

    private static let handleWidth: CGFloat = 9
    private static let stops = 13

    var body: some View {
        GeometryReader { geo in
            let inset = Self.handleWidth / 2
            let trackWidth = max(geo.size.width - inset * 2, 1)
            let colors = (0..<Self.stops).map { i in
                Color(rgb: HSV(h: Double(i) * 360 / Double(Self.stops - 1), s: 1, v: 1).rgb)
            }
            let cx = inset + hue / 360 * trackWidth
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: trackWidth, height: geo.size.height)
                    .offset(x: inset)
                Capsule()
                    .fill(.white)
                    .overlay(Capsule().stroke(Color.black.opacity(0x33 / 255), lineWidth: 1))
                    .frame(width: Self.handleWidth, height: geo.size.height + 8)
                    .position(x: cx, y: geo.size.height / 2)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        hue = min(max((g.location.x - inset) / trackWidth, 0), 1) * 360
                    }
            )
        }
    }
}

// MARK: - HSV helpers

/// `android.graphics.Color.colorToHSV` / `HSVToColor` and `CustomThemeColor`
/// normalize / toHex.
struct HSV {
    var h: Double  // 0…360
    var s: Double  // 0…1
    var v: Double  // 0…1

    init(h: Double, s: Double, v: Double) { self.h = h; self.s = s; self.v = v }

    init(rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        self.h = h
        self.s = mx == 0 ? 0 : d / mx
        self.v = mx
    }

    var rgb: UInt32 {
        let c = v * s
        let hh = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hh {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = v - c
        func byte(_ d: Double) -> UInt32 { UInt32(min(max(((d + m) * 255).rounded(), 0), 255)) }
        return byte(r1) << 16 | byte(g1) << 8 | byte(b1)
    }

    /// `#RRGGBB`.
    static func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb & 0xFFFFFF) }

    /// `#RRGGBB` / `#RGB` (with or without `#`) → upper-case `#RRGGBB`; nil otherwise.
    static func normalize(_ input: String?) -> String? {
        guard var raw = input?.trimmingCharacters(in: .whitespaces).uppercased() else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        switch raw.count {
        case 3: return "#" + raw.map { "\($0)\($0)" }.joined()
        case 6: return "#" + raw
        default: return nil
        }
    }

    static func parse(_ hex: String) -> UInt32? {
        guard let n = normalize(hex) else { return nil }
        return UInt32(n.dropFirst(), radix: 16)
    }

    /// `contrastingTextColor`: #1A1A2E on light swatches (luminance > 0.5), white otherwise.
    static func contrastingText(_ rgb: UInt32) -> Color {
        func lin(_ c: UInt32) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin((rgb >> 16) & 0xFF) + 0.7152 * lin((rgb >> 8) & 0xFF) + 0.0722 * lin(rgb & 0xFF)
        return l > 0.5 ? Color(rgb: 0x1A1A2E) : .white
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

extension UIColor {
    /// `0xRRGGBB` of this colour (alpha dropped).
    var rgb24: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ c: CGFloat) -> UInt32 { UInt32(min(max((c * 255).rounded(), 0), 255)) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
