import SwiftUI

struct TunnelBackgroundView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            Canvas { canvas, size in
                draw(canvas: &canvas, size: size, t: ctx.date.timeIntervalSinceReferenceDate)
            }
            .background(.black)
        }
    }

    private func draw(canvas: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let w = size.width
        let h = size.height
        let cx = w * 0.5
        let cy = h * 0.5

        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        let layers = 24
        let speed = 0.45
        let depth = (t * speed).truncatingRemainder(dividingBy: 1.0)

        // Receding concentric rectangles, parallax rotation
        let rot = sin(t * 0.18) * 0.12
        let cosR = cos(rot), sinR = sin(rot)

        let baseColors: [(r: Double, g: Double, b: Double)] = [
            (0.04, 0.02, 0.10),
            (0.10, 0.04, 0.18),
            (0.06, 0.10, 0.22),
            (0.10, 0.04, 0.18),
        ]

        for i in (0..<layers).reversed() {
            let z = Double(i) + depth
            let scale = 0.04 + z * 0.06
            let rectW = w * scale * 1.6
            let rectH = h * scale * 1.6

            // Apply slight rotation around center via affine transform
            var transform = CGAffineTransform(translationX: cx, y: cy)
            transform = transform.rotated(by: rot)
            transform = transform.translatedBy(x: -rectW / 2, y: -rectH / 2)
            _ = (cosR, sinR)

            let path = Path(roundedRect: CGRect(x: 0, y: 0, width: rectW, height: rectH),
                            cornerRadius: rectW * 0.04)
                .applying(transform)

            let c = baseColors[i % baseColors.count]
            // Brightness falls off with distance (smaller layers = farther)
            let dim = max(0.05, 1.0 - Double(i) / Double(layers))
            let alpha = dim * 0.55
            let color = Color(red: c.r * dim + 0.02,
                              green: c.g * dim + 0.02,
                              blue: c.b * dim + 0.04,
                              opacity: alpha)
            canvas.stroke(path, with: .color(color), lineWidth: 2)

            // Subtle inner glow
            if i < 4 {
                let glow = Color(red: 0.4, green: 0.5, blue: 1.0, opacity: 0.10 - Double(i) * 0.025)
                canvas.stroke(path, with: .color(glow), lineWidth: 6)
            }
        }

        // Vignette
        let vignette = Gradient(colors: [
            .black.opacity(0.0),
            .black.opacity(0.55),
        ])
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                vignette,
                center: CGPoint(x: cx, y: cy),
                startRadius: min(w, h) * 0.25,
                endRadius: max(w, h) * 0.7
            )
        )
    }
}

struct LoginScrimGradient: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.0), location: 0.0),
                .init(color: .black.opacity(0.25), location: 0.5),
                .init(color: .black.opacity(0.88), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}
