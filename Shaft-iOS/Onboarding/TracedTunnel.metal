#include <metal_stdlib>
using namespace metal;

// 1:1 port of the Pixiv-Shaft landing "infinite illustration gallery" tunnel:
// Android AGSL (TracedTunnelView.kt) / shaft-web WebGL2 (tunnel-shader.tsx).
// Raymarched unit-box tunnel; each wall tile samples a random image from a
// 16x16 atlas (2560x2560, 160px tiles).

constant float GRID_COLS = 16.0;
constant float TILE_SIZE = 160.0;
constant float TOTAL_IMAGES = 256.0;
constant float INV_GRID_COLS = 0.0625;

struct TunnelUniforms {
    float2 resolution;
    float  time;
    float  alpha;
    float2 atlasSize;
    float  mixAmount;   // 0 = low-res atlas, 1 = full-res — cross-fades between them
    float  padding;
};

// Eased stop-and-go pulse: glide, then briefly pause every `d` seconds.
static float tick(float t, float d) {
    float m = fract(t / d);
    m = m * m * (3.0 - 2.0 * m);
    return (floor(t / d) + m) * d;
}

static float2 rot2(float2 v, float c, float s) {
    return float2(v.x * c + v.y * s, -v.x * s + v.y * c);
}

static float hash21(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Fullscreen triangle, no vertex buffers — positions come from vertex_id.
vertex float4 tunnelVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

// Ray math stays float (time-driven magnitudes outgrow half precision); the
// color path is half — 8-bit sources, and half doubles ALU throughput on
// Apple GPUs, which matters for a fullscreen fill-rate-bound pass.
fragment half4 tunnelFragment(float4 position [[position]],
                              constant TunnelUniforms &u [[buffer(0)]],
                              texture2d<half> atlasLow [[texture(0)]],
                              texture2d<half> atlasFull [[texture(1)]]) {
    constexpr sampler smp(address::clamp_to_edge, filter::linear, mip_filter::none);

    // GL frag coords are y-up, Metal's are y-down — flip for parity.
    float2 fragCoord = float2(position.x, u.resolution.y - position.y);
    float2 uv = (fragCoord - u.resolution * 0.5) / u.resolution.y;

    float t = u.time;
    float tickTm = t + tick(t, 6.0) * 0.5;

    // Two slow oscillating camera rotations.
    float a1 = sin(tickTm * 0.3) * 0.4;
    float a2 = sin(tickTm * 0.1) * 2.0;
    float c1 = cos(a1), s1 = sin(a1);
    float c2 = cos(a2), s2 = sin(a2);

    float3 ro = float3(0.0, 0.0, tickTm);
    float3 r = normalize(float3(uv, 1.0));

    r.xz = rot2(r.xz, c1, s1);
    r.xy = rot2(r.xy, c2, s2);

    // Ray vs the 4 walls of a unit-box tunnel; take the nearest hit.
    float dB = r.y < 0.0 ? (-1.0 - ro.y) / r.y : 1e8;
    float dT = r.y > 0.0 ? ( 1.0 - ro.y) / r.y : 1e8;
    float dL = r.x < 0.0 ? (-1.0 - ro.x) / r.x : 1e8;
    float dR = r.x > 0.0 ? ( 1.0 - ro.x) / r.x : 1e8;

    float dH = min(dB, dT);
    float dV = min(dL, dR);
    float d  = min(dH, dV);

    float3 hp = ro + r * d;

    float3 n;
    float2 tuv;
    if (dH < dV) {
        n   = float3(0.0, dB < dT ? 1.0 : -1.0, 0.0);
        tuv = hp.xz + float2(0.0, n.y);
    } else {
        n   = float3(dL < dR ? 1.0 : -1.0, 0.0, 0.0);
        tuv = hp.yz + float2(n.x, 0.0);
    }

    tuv *= 2.0;
    float2 id = floor(tuv);
    float2 luv = tuv - id - 0.5;

    // Rounded-box "picture frame" mask.
    float bx = length(max(abs(luv) - 0.42, float2(0.0))) - 0.05;
    float inside = smoothstep(0.008, 0.0, bx);
    float sh = clamp(0.5 - bx * 10.0, 0.0, 1.0);

    // Per-tile atlas lookup.
    float imgIndex = floor(hash21(id) * TOTAL_IMAGES);
    float atlasRow = floor(imgIndex * INV_GRID_COLS);
    float atlasCol = imgIndex - atlasRow * GRID_COLS;

    float2 imgUV = (float2(atlasCol, atlasRow) + luv + 0.5) * TILE_SIZE;
    float2 sampleUV = imgUV / u.atlasSize;
    // Cross-fade low→full; at rest only one texture is fetched.
    half3 imgCol =
          u.mixAmount >= 1.0 ? atlasFull.sample(smp, sampleUV).rgb
        : u.mixAmount <= 0.0 ? atlasLow.sample(smp, sampleUV).rgb
        : mix(atlasLow.sample(smp, sampleUV).rgb,
              atlasFull.sample(smp, sampleUV).rgb, half(u.mixAmount));

    half3 sampleCol = mix(half3(0.02h), imgCol * half(sh), half(inside));
    float dif = max(dot(normalize(float3(0.0, 0.0, 3.0) - hp + ro), n), 0.0);
    sampleCol *= half(dif * 0.35 + 0.65);

    // Distance fog → vanishing point fades to black.
    sampleCol *= half(1.0 / (1.0 + d * d * 0.02));

    // Gamma.
    half3 gc = pow(max(sampleCol, half3(0.0h)), half3(0.4545h));

    // Opaque over black, so multiplying by alpha fades in from black.
    return half4(gc * half(u.alpha), 1.0h);
}
