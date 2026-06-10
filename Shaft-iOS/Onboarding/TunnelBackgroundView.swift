import SwiftUI
import MetalKit
import ImageIO

// 1:1 iOS port of the Pixiv-Shaft landing tunnel (Android TracedTunnelView.kt
// AGSL / shaft-web tunnel-shader.tsx WebGL2). The raymarch lives in
// TracedTunnel.metal; this file drives it: progressive atlas loading
// (low-res boots the effect, full-res cross-fades in) and the 1.2s fade-in.
struct TunnelBackgroundView: View {
    var body: some View {
        TracedTunnelMetalView()
            .background(Color.black)
            .allowsHitTesting(false)
    }
}

// Match the display's refresh rate (ProMotion included) and cap the drawable
// scale: photos + fog + motion can't tell 2x from 3x, but fragment count
// drops ~2.25x — same idea as the web port's devicePixelRatio clamp.
private final class TunnelMTKView: MTKView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let screen = window?.screen else { return }
        preferredFramesPerSecond = screen.maximumFramesPerSecond
        contentScaleFactor = min(screen.scale, 2.0)
    }
}

private struct TracedTunnelMetalView: UIViewRepresentable {
    func makeCoordinator() -> TunnelRenderer { TunnelRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let gpu = TunnelGPU.shared
        let view = TunnelMTKView(frame: .zero, device: gpu.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = true
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        gpu.viewAttached()
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    static func dismantleUIView(_ view: MTKView, coordinator: TunnelRenderer) {
        view.delegate = nil
        TunnelGPU.shared.viewDetached()
    }
}

// Matches TunnelUniforms in TracedTunnel.metal (32 bytes).
private struct TunnelUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var alpha: Float
    var atlasSize: SIMD2<Float>
    var mixAmount: Float
    var padding: Float = 0
}

// Device, pipeline, atlas textures and the animation clock, shared by every
// tunnel view in the process. The onboarding→login transition cross-fades two
// views for ~0.35s; per-view state would compile a second pipeline mid-
// animation, decode both atlases again, double the texture memory and restart
// the fade from black. Main-thread only (MTKView draws on the main loop).
private final class TunnelGPU {
    static let shared = TunnelGPU()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let pipeline: MTLRenderPipelineState?

    var atlasLow: MTLTexture?
    var atlasFull: MTLTexture?
    var bootedAt: CFTimeInterval?
    var bootedWithFull = false
    var crossfadeAt: CFTimeInterval?
    var lastDrawAt: CFTimeInterval = 0
    private var loadingStarted = false
    private var attachedViews = 0

    // Atlas coordinate space is always the full-res grid (16 * 160), even while
    // sampling the low-res placeholder — UVs are normalized against this.
    static let atlasSize: Float = 2560
    static let fadeIn = 1.2      // web FADE
    static let crossfade = 0.9   // web CROSSFADE_MS

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.queue = device?.makeCommandQueue()
        if let device,
           let library = device.makeDefaultLibrary(),
           let vertexFn = library.makeFunction(name: "tunnelVertex"),
           let fragmentFn = library.makeFunction(name: "tunnelFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        } else {
            self.pipeline = nil
        }
    }

    func viewAttached() {
        attachedViews += 1
        startLoadingIfNeeded()
    }

    func viewDetached() {
        attachedViews -= 1
        guard attachedViews <= 0 else { return }
        // Last tunnel left the screen (login finished) — free ~27MB of atlas
        // textures. A later logout reboots the effect from scratch.
        atlasLow = nil
        atlasFull = nil
        bootedAt = nil
        bootedWithFull = false
        crossfadeAt = nil
        loadingStarted = false
    }

    private func startLoadingIfNeeded() {
        guard !loadingStarted, let device else { return }
        loadingStarted = true
        let loader = MTKTextureLoader(device: device)
        for (name, isFull) in [("tunnel-atlas-lq", false), ("tunnel-atlas", true)] {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let texture = Self.loadAtlas(named: name, loader: loader) else { return }
                DispatchQueue.main.async {
                    self?.atlasArrived(texture, isFull: isFull)
                }
            }
        }
    }

    private func atlasArrived(_ texture: MTLTexture, isFull: Bool) {
        guard attachedViews > 0 else { return }  // decoded after the last view left
        if isFull {
            atlasFull = texture
        } else if bootedWithFull {
            return  // full-res won the race; the placeholder is never sampled
        } else {
            atlasLow = texture
        }
        if bootedAt == nil {
            bootedAt = CACurrentMediaTime()
            bootedWithFull = isFull
        } else if isFull, !bootedWithFull {
            crossfadeAt = CACurrentMediaTime()
        }
    }

    private static func loadAtlas(named name: String, loader: MTKTextureLoader) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // SRGB false: sample raw bytes and gamma-correct in the shader, like the
        // WebGL/AGSL originals.
        return try? loader.newTexture(cgImage: image, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
    }
}

final class TunnelRenderer: NSObject, MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let gpu = TunnelGPU.shared
        guard let queue = gpu.queue, let pipeline = gpu.pipeline,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        // The display link pauses in the background but the wall clock doesn't:
        // shift the time origin across any gap so the camera resumes where it
        // was instead of teleporting (the web port's pause/resume clock).
        if gpu.lastDrawAt > 0, let bootedAt = gpu.bootedAt {
            let gap = now - gpu.lastDrawAt
            if gap > 0.5 {
                gpu.bootedAt = bootedAt + gap
                if let crossfadeAt = gpu.crossfadeAt { gpu.crossfadeAt = crossfadeAt + gap }
            }
        }
        gpu.lastDrawAt = now

        guard let bootedAt = gpu.bootedAt, let texFull = gpu.atlasFull ?? gpu.atlasLow else {
            // Atlas still decoding — hold black, like the originals.
            buffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            return
        }

        let mixAmount: Float
        if gpu.bootedWithFull {
            mixAmount = 1
        } else if let crossfadeAt = gpu.crossfadeAt {
            mixAmount = Float(min((now - crossfadeAt) / TunnelGPU.crossfade, 1))
            if mixAmount >= 1 { gpu.atlasLow = nil }  // placeholder no longer sampled
        } else {
            mixAmount = 0
        }
        let texLow = gpu.atlasLow ?? texFull

        let t = Float(now - bootedAt)
        var uniforms = TunnelUniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: t,
            alpha: min(t / Float(TunnelGPU.fadeIn), 1),
            atlasSize: SIMD2(TunnelGPU.atlasSize, TunnelGPU.atlasSize),
            mixAmount: mixAmount
        )

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TunnelUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texLow, index: 0)
        encoder.setFragmentTexture(texFull, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
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
