// CPM35Shader.metal
// DAZZ Camera — CPM35 (Kodak Gold 200 / ColorPlus 200)
//
// Pipeline 顺序：
//   Camera Frame → Chromatic Aberration → Tone Curve → RGB Channel Shift
//   → Saturation → Contrast → Temperature/Tint → Highlight Warmth
//   → Halation → Bloom → Film Grain → Noise → Vignette → Output
//
// 色彩科学（Kodak Gold / ColorPlus 核心）：
//   1. Warm Tone      — R×1.04, G×1.02, B×0.96（暖色，区别于 FQS 的绿调）
//   2. Highlight Warm — 高光区额外暖推（Kodak 式暖高光，非 FQS 的 Halation 发红）
//   3. Light Grain    — grain_intensity=0.16, grain_size=1.6（轻颗粒，干净出片）
//
// 与 FQS 的关键差异：
//   FQS: R-4%, G+5%, B+2% → 偏冷绿（Fuji Superia 风格）
//   CPM35: R+4%, G+2%, B-4% → 偏暖（Kodak Gold 风格）
//   FQS: grain=0.28（明显）    CPM35: grain=0.16（轻）
//   FQS: halation=0.15（高光发红）  CPM35: halation=0.06（克制）

#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点着色器（与 FQSShader.metal 结构完全一致）

struct CPM35VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct CPM35VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex CPM35VertexOut cpm35VertexShader(CPM35VertexIn in [[stage_in]]) {
    CPM35VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// MARK: - CPM35 Uniform 参数

struct CPM35Params {
    // ── 核心色彩 ──────────────────────────────────────────────────
    float contrast;          // 对比度倍数（推荐 1.02，比 FQS 略高）
    float saturation;        // 饱和度倍数（推荐 1.08）
    float temperatureShift;  // 色温偏移 K（推荐 +120，暖色）
    float tintShift;         // 色调偏移（推荐 +4，轻微品红，Kodak 特征）

    // ── RGB Channel Shift（Kodak Gold 暖色偏移）──────────────────
    float colorBiasR;        // R 通道偏移（推荐 +0.04，暖红）
    float colorBiasG;        // G 通道偏移（推荐 +0.02，轻微）
    float colorBiasB;        // B 通道偏移（推荐 -0.04，压蓝去冷感）

    // ── 胶片颗粒 ──────────────────────────────────────────────────
    float grainIntensity;    // 颗粒强度（推荐 0.16，比 FQS 轻）
    float grainSize;         // 颗粒大小（推荐 1.6，比 FQS 细）
    float time;              // 时间种子（每帧更新）

    // ── Highlight Warmth（Kodak 式暖高光）────────────────────────
    float halationAmount;    // 高光暖推强度（推荐 0.06，克制）
    float bloomAmount;       // 柔光强度（推荐 0.05）

    // ── 镜头效果 ──────────────────────────────────────────────────
    float vignetteAmount;    // 暗角强度（推荐 0.10，比 FQS 轻）
    float chromaticAberration; // 色差强度（推荐 0.15）

    // ── 噪声 ──────────────────────────────────────────────────────
    float luminanceNoise;    // 亮度噪声（推荐 0.05）
    float chromaNoise;       // 色度噪声（推荐 0.03）
};

// MARK: - 工具函数

/// 伪随机数生成（与 FQSShader 保持一致）
float cpm35Random(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// CPM35 Tone Curve（Kodak Gold 胶片曲线）
/// 控制点（归一化）：
///   (0.000, 0.000) (0.125, 0.102) (0.251, 0.235)
///   (0.502, 0.494) (0.753, 0.816) (1.000, 0.988)
/// 特点：阴影轻压（比 FQS 更自然），高光柔和 roll-off（Kodak 特征）
float cpm35ToneCurve(float v) {
    v = clamp(v, 0.0, 1.0);

    // 控制点（Kodak Gold 胶片曲线）
    const float x0 = 0.0,       y0 = 0.0;
    const float x1 = 0.12549,   y1 = 0.10196;  // 32/255 → 26/255
    const float x2 = 0.25098,   y2 = 0.23529;  // 64/255 → 60/255
    const float x3 = 0.50196,   y3 = 0.49412;  // 128/255 → 126/255
    const float x4 = 0.75294,   y4 = 0.81569;  // 192/255 → 208/255
    const float x5 = 1.0,       y5 = 0.98824;  // 255/255 → 252/255

    float t;

    if (v <= x1) {
        t = (v - x0) / (x1 - x0);
        t = t * t * (3.0 - 2.0 * t);
        return mix(y0, y1, t);
    } else if (v <= x2) {
        t = (v - x1) / (x2 - x1);
        t = t * t * (3.0 - 2.0 * t);
        return mix(y1, y2, t);
    } else if (v <= x3) {
        t = (v - x2) / (x3 - x2);
        t = t * t * (3.0 - 2.0 * t);
        return mix(y2, y3, t);
    } else if (v <= x4) {
        t = (v - x3) / (x4 - x3);
        t = t * t * (3.0 - 2.0 * t);
        return mix(y3, y4, t);
    } else {
        t = (v - x4) / (x5 - x4);
        t = t * t * (3.0 - 2.0 * t);
        return mix(y4, y5, t);
    }
}

/// 对比度调整（以 0.5 为中心）
float3 cpm35Contrast(float3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度调整（Rec.709 亮度权重）
float3 cpm35Saturation(float3 c, float saturation) {
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(lum), c, saturation), 0.0, 1.0);
}

/// 色温 + Tint（Kodak 暖色版本）
/// 正 tempShift = 暖（R增，B减），与 FQS 的负值偏冷相反
float3 cpm35TemperatureTint(float3 c, float tempShift, float tintShift) {
    float ts = tempShift / 1000.0;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    float strength = lum * 0.8 + 0.2;
    // 正温度 = 暖：R增，B减
    c.r = clamp(c.r + ts * 0.018 * strength, 0.0, 1.0);
    c.b = clamp(c.b - ts * 0.022 * strength, 0.0, 1.0);

    // Tint：正值偏品红（Kodak 特征，轻微品红）
    float tint = tintShift / 1000.0;
    float midtoneMask = clamp(1.0 - abs(lum - 0.5) * 1.5, 0.0, 1.0);
    c.r = clamp(c.r + tint * 0.006 * midtoneMask, 0.0, 1.0);
    c.b = clamp(c.b + tint * 0.004 * midtoneMask, 0.0, 1.0);

    return c;
}

/// Kodak Gold 暖高光（区别于 FQS 的 Halation 发红）
/// Kodak 的高光特征：整体暖推，不像 FQS 那样偏红
float3 cpm35HighlightWarmth(float3 c, float amount) {
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    if (lum > 0.55) {
        float warmMask = clamp((lum - 0.55) / 0.45, 0.0, 1.0);
        warmMask = warmMask * warmMask;
        // 暖高光：R微增，G微增，B轻压
        float3 warmColor = float3(
            c.r * (1.0 + amount * 0.04),
            c.g * (1.0 + amount * 0.016),
            c.b * (1.0 - amount * 0.05)
        );
        c = mix(c, warmColor, warmMask);
    }
    return clamp(c, 0.0, 1.0);
}

/// 暗角效果
float cpm35Vignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// MARK: - CPM35 片段着色器

fragment float4 cpm35FragmentShader(
    CPM35VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> grainTexture  [[texture(1)]],
    constant CPM35Params &params   [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    float2 uv = in.texCoord;

    // ── Pass 1: 色差 (Chromatic Aberration) ─────────────────────────────────
    // CPM35 参数：chromaticAberration = 0.15（比 FQS 的 0.4 克制）
    float3 color;
    if (params.chromaticAberration > 0.0) {
        float ca = params.chromaticAberration * 0.01;
        float r = cameraTexture.sample(s, uv + float2(ca,  0.0)).r;
        float g = cameraTexture.sample(s, uv).g;
        float b = cameraTexture.sample(s, uv - float2(ca,  0.0)).b;
        color = float3(r, g, b);
    } else {
        color = cameraTexture.sample(s, uv).rgb;
    }

    // ── Pass 2: Tone Curve（Kodak 胶片曲线）─────────────────────────────────
    color.r = cpm35ToneCurve(color.r);
    color.g = cpm35ToneCurve(color.g);
    color.b = cpm35ToneCurve(color.b);

    // ── Pass 3: RGB Channel Shift（Kodak Gold 暖色偏移）──────────────────────
    // R×1.04, G×1.02, B×0.96（与 FQS 的 R×0.96, G×1.05, B×1.02 相反方向）
    color.r = clamp(color.r * (1.0 + params.colorBiasR), 0.0, 1.0);
    color.g = clamp(color.g * (1.0 + params.colorBiasG), 0.0, 1.0);
    color.b = clamp(color.b * (1.0 + params.colorBiasB), 0.0, 1.0);

    // ── Pass 4: 饱和度（1.08）────────────────────────────────────────────────
    color = cpm35Saturation(color, params.saturation);

    // ── Pass 5: 对比度（1.02，比 FQS 的 0.92 略高，Kodak 更通透）────────────
    color = cpm35Contrast(color, params.contrast);

    // ── Pass 6: 色温 + Tint（+120K 暖色，+4 tint 轻微品红）─────────────────
    color = cpm35TemperatureTint(color, params.temperatureShift, params.tintShift);

    // ── Pass 7: Kodak 暖高光（高光区额外暖推，区别于 FQS 的发红 Halation）────
    color = cpm35HighlightWarmth(color, params.halationAmount);

    // ── Pass 8: Halation（克制的高光溢出，0.06）──────────────────────────────
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (params.halationAmount > 0.0 && lum > 0.80) {
        float halationMask = clamp((lum - 0.80) / 0.20, 0.0, 1.0);
        halationMask = halationMask * halationMask;
        // CPM35 Halation：暖橙色（Kodak 特征，区别于 FQS 的暖红）
        float3 halationColor = float3(
            color.r * 1.08,
            color.g * 1.02,
            color.b * 0.90
        );
        color = mix(color, halationColor, halationMask * params.halationAmount * 0.5);
    }

    // ── Pass 9: Bloom（轻柔光，0.05）─────────────────────────────────────────
    if (params.bloomAmount > 0.0 && lum > 0.82) {
        float bloom = clamp((lum - 0.82) * params.bloomAmount * 2.0, 0.0, 0.2);
        // CPM35 Bloom：暖色调（R略多于B）
        color = clamp(color + float3(bloom * 0.9, bloom * 0.75, bloom * 0.55), 0.0, 1.0);
    }

    // ── Pass 10: 胶片颗粒（Film Grain，轻颗粒）──────────────────────────────
    // grain_intensity=0.16, grain_size=1.6（比 FQS 的 0.28/1.8 更轻更细）
    if (params.grainIntensity > 0.0) {
        float2 grainUV = uv * params.grainSize;
        float3 grainSample = grainTexture.sample(s, grainUV).rgb;

        // 锁定 24fps 颗粒（防止闪烁）
        float timeSeed = floor(params.time * 24.0) / 24.0;
        float dynamicGrain = cpm35Random(uv, timeSeed) - 0.5;

        // 混合纹理颗粒和程序颗粒（7:3）
        float grain = mix(grainSample.r - 0.5, dynamicGrain, 0.3);

        // 颗粒强度随亮度变化：中间调最明显
        float grainLum = dot(color, float3(0.2126, 0.7152, 0.0722));
        float grainMask = clamp(1.0 - abs(grainLum - 0.45) * 1.2, 0.3, 1.0);

        // CPM35 颗粒：以亮度颗粒为主（70%），少量彩色颗粒（30%）
        // 比 FQS 的 60/40 更偏向亮度颗粒，更接近 Kodak 扫描质感
        float grainR = cpm35Random(uv, timeSeed + 0.1) - 0.5;
        float grainG = cpm35Random(uv, timeSeed + 0.2) - 0.5;
        float grainB = cpm35Random(uv, timeSeed + 0.3) - 0.5;
        float3 colorGrain = float3(grainR, grainG, grainB) * 0.25;
        float3 lumaGrain  = float3(grain);

        float3 totalGrain = mix(lumaGrain, colorGrain, 0.3);  // 70% 亮度 + 30% 彩色
        color = clamp(color + totalGrain * params.grainIntensity * 0.22 * grainMask,
                      0.0, 1.0);
    }

    // ── Pass 11: 亮度噪声 + 色度噪声（轻扫描噪声）──────────────────────────
    if (params.luminanceNoise > 0.0) {
        float noise = cpm35Random(uv, params.time * 0.5) - 0.5;
        float darkMask = 1.0 - clamp(lum * 1.5, 0.0, 1.0);
        color = clamp(color + noise * params.luminanceNoise * 0.15 * darkMask, 0.0, 1.0);
    }
    if (params.chromaNoise > 0.0) {
        float3 chromaNoise = float3(
            cpm35Random(uv, params.time * 0.3 + 10.0) - 0.5,
            cpm35Random(uv, params.time * 0.3 + 20.0) - 0.5,
            cpm35Random(uv, params.time * 0.3 + 30.0) - 0.5
        );
        float darkMask = 1.0 - clamp(lum * 2.0, 0.0, 1.0);
        color = clamp(color + chromaNoise * params.chromaNoise * 0.10 * darkMask, 0.0, 1.0);
    }

    // ── Pass 12: 暗角（Vignette，0.10，比 FQS 的 0.15 更轻）────────────────
    if (params.vignetteAmount > 0.0) {
        float vignette = cpm35Vignette(uv, params.vignetteAmount);
        color *= vignette;
    }

    return float4(color, 1.0);
}
