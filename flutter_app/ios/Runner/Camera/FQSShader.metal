// FQSShader.metal
// DAZZ Camera — FQS (Fuji Superia 400 + Kodak Portra 400)
//
// Pipeline 顺序：
//   Camera Frame → Tone Curve → RGB Channel Shift → Saturation
//   → Temperature/Tint → Skin Tone Guard → Grain → Halation/Bloom
//   → Chromatic Aberration → Vignette → Output
//
// 设计原则（FQS 复刻三要素）：
//   1. Fuji Green Tone  — G+5%, 中间调微绿
//   2. Soft Contrast    — 胶片曲线压低阴影、抬高中间调
//   3. Film Grain       — grain_intensity=0.28, grain_size=1.8

#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点着色器（复用 CameraShaders.metal 的结构）

struct FQSVertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct FQSVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex FQSVertexOut fqsVertexShader(FQSVertexIn in [[stage_in]]) {
    FQSVertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// MARK: - FQS Uniform 参数

struct FQSParams {
    // ── 核心色彩 ──────────────────────────────────────────────────
    float contrast;          // 对比度倍数（推荐 0.92）
    float saturation;        // 饱和度倍数（推荐 1.05）
    float temperatureShift;  // 色温偏移 K（推荐 -40）
    float tintShift;         // 色调偏移（推荐 -18，偏绿）

    // ── RGB Channel Shift（Fuji Superia 色偏）──────────────────────
    float colorBiasR;        // R 通道偏移（推荐 -0.04）
    float colorBiasG;        // G 通道偏移（推荐 +0.05）
    float colorBiasB;        // B 通道偏移（推荐 +0.02）

    // ── 胶片颗粒 ──────────────────────────────────────────────────
    float grainIntensity;    // 颗粒强度（推荐 0.28）
    float grainSize;         // 颗粒大小（推荐 1.8）
    float time;              // 时间种子（每帧更新，使颗粒动态变化）

    // ── Highlight Halation（高光发光）─────────────────────────────
    float halationAmount;    // 高光发光强度（推荐 0.15）
    float bloomAmount;       // 柔光强度（推荐 0.10）

    // ── 镜头效果 ──────────────────────────────────────────────────
    float vignetteAmount;    // 暗角强度（推荐 0.15）
    float chromaticAberration; // 色差强度（推荐 0.4，映射到像素偏移）

    // ── 噪声 ──────────────────────────────────────────────────────
    float luminanceNoise;    // 亮度噪声（推荐 0.08）
    float chromaNoise;       // 色度噪声（推荐 0.05）
};

// MARK: - 工具函数

/// 伪随机数生成（基于 UV + 时间种子）
float fqsRandom(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// FQS 胶片 Tone Curve（三次样条，6 个控制点）
/// 控制点：(0,0) (32,28) (64,58) (128,120) (192,205) (255,255) → 归一化
float fqsToneCurve(float v) {
    v = clamp(v, 0.0, 1.0);

    // 分段三次平滑插值（smoothstep）
    // 段 0: [0, 0.125]  → [0, 0.110]
    // 段 1: [0.125, 0.25] → [0.110, 0.227]
    // 段 2: [0.25, 0.502] → [0.227, 0.471]
    // 段 3: [0.502, 0.753] → [0.471, 0.804]
    // 段 4: [0.753, 1.0]  → [0.804, 1.0]

    const float x0 = 0.0,       y0 = 0.0;
    const float x1 = 0.12549,   y1 = 0.10980;  // 32/255, 28/255
    const float x2 = 0.25098,   y2 = 0.22745;  // 64/255, 58/255
    const float x3 = 0.50196,   y3 = 0.47059;  // 128/255, 120/255
    const float x4 = 0.75294,   y4 = 0.80392;  // 192/255, 205/255
    const float x5 = 1.0,       y5 = 1.0;

    float t, result;

    if (v <= x1) {
        t = (v - x0) / (x1 - x0);
        t = t * t * (3.0 - 2.0 * t);
        result = mix(y0, y1, t);
    } else if (v <= x2) {
        t = (v - x1) / (x2 - x1);
        t = t * t * (3.0 - 2.0 * t);
        result = mix(y1, y2, t);
    } else if (v <= x3) {
        t = (v - x2) / (x3 - x2);
        t = t * t * (3.0 - 2.0 * t);
        result = mix(y2, y3, t);
    } else if (v <= x4) {
        t = (v - x3) / (x4 - x3);
        t = t * t * (3.0 - 2.0 * t);
        result = mix(y3, y4, t);
    } else {
        t = (v - x4) / (x5 - x4);
        t = t * t * (3.0 - 2.0 * t);
        result = mix(y4, y5, t);
    }

    return clamp(result, 0.0, 1.0);
}

/// 对比度调整（以 0.5 为中心）
float3 fqsContrast(float3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度调整（Rec.709 亮度权重）
float3 fqsSaturation(float3 c, float saturation) {
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(lum), c, saturation), 0.0, 1.0);
}

/// 色温 + Tint 偏移（简化 RGB 空间实现）
float3 fqsTemperatureTint(float3 c, float tempShift, float tintShift) {
    // 色温：负值偏冷（R减，B增）
    float ts = tempShift / 1000.0;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    float strength = lum * 0.8 + 0.2;  // 阴影区域减弱偏移
    c.r = clamp(c.r + ts * -0.018 * strength, 0.0, 1.0);
    c.b = clamp(c.b + ts *  0.022 * strength, 0.0, 1.0);

    // Tint：负值偏绿（G增）
    float tint = tintShift / 1000.0;
    float midtoneMask = 1.0 - abs(lum - 0.5) * 1.5;
    midtoneMask = clamp(midtoneMask, 0.0, 1.0);
    c.g = clamp(c.g + tint * -0.008 * midtoneMask, 0.0, 1.0);

    return c;
}

/// Kodak Portra 肤色保护（防止绿偏破坏肤色）
float3 fqsSkinToneGuard(float3 c) {
    // 检测肤色区域：R > G > B，且 R-B > 0.08
    float skinMask = 0.0;
    if (c.r > c.g && c.g > c.b && (c.r - c.b) > 0.08) {
        skinMask = clamp((c.r - c.b - 0.08) * 3.0, 0.0, 1.0);
    }
    // 肤色区域：微提 R，防止绿偏过重
    c.r = clamp(c.r + skinMask * 0.012, 0.0, 1.0);
    c.g = clamp(c.g + skinMask * 0.004, 0.0, 1.0);
    return c;
}

/// 暗角效果
float fqsVignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// MARK: - FQS 片段着色器

fragment float4 fqsFragmentShader(
    FQSVertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> grainTexture  [[texture(1)]],
    constant FQSParams &params     [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    float2 uv = in.texCoord;

    // ── Pass 1: 色差 (Chromatic Aberration) ─────────────────────────────────
    // FQS 参数：chromaticAberration = 0.4（映射到 0.004 像素偏移）
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

    // ── Pass 2: Tone Curve（胶片曲线）────────────────────────────────────────
    // 分别对 RGB 三通道应用曲线（保留色偏）
    color.r = fqsToneCurve(color.r);
    color.g = fqsToneCurve(color.g);
    color.b = fqsToneCurve(color.b);

    // ── Pass 3: RGB Channel Shift（Fuji Superia 色偏）─────────────────────────
    // R*0.96, G*1.05, B*1.02
    color.r = clamp(color.r * (1.0 + params.colorBiasR), 0.0, 1.0);
    color.g = clamp(color.g * (1.0 + params.colorBiasG), 0.0, 1.0);
    color.b = clamp(color.b * (1.0 + params.colorBiasB), 0.0, 1.0);

    // ── Pass 4: 饱和度（1.05）────────────────────────────────────────────────
    color = fqsSaturation(color, params.saturation);

    // ── Pass 5: 对比度（0.92，低对比胶片感）─────────────────────────────────
    color = fqsContrast(color, params.contrast);

    // ── Pass 6: 色温 + Tint（-40K, -18 tint）────────────────────────────────
    color = fqsTemperatureTint(color, params.temperatureShift, params.tintShift);

    // ── Pass 7: Kodak Portra 肤色保护 ────────────────────────────────────────
    color = fqsSkinToneGuard(color);

    // ── Pass 8: Highlight Halation（高光发光，模拟胶片高光溢出）──────────────
    // 算法：提取亮度 > 0.8 的区域，模拟高斯模糊后叠加（单 Pass 近似）
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (params.halationAmount > 0.0 && lum > 0.75) {
        float halationMask = clamp((lum - 0.75) / 0.25, 0.0, 1.0);
        halationMask = halationMask * halationMask;  // 二次曲线，高光区域更明显
        // Halation 颜色：偏暖红（胶片高光发红）
        float3 halationColor = float3(
            color.r * 1.15,
            color.g * 0.95,
            color.b * 0.80
        );
        color = mix(color, halationColor, halationMask * params.halationAmount);
    }

    // ── Pass 9: Bloom（柔光）─────────────────────────────────────────────────
    if (params.bloomAmount > 0.0 && lum > 0.80) {
        float bloom = clamp((lum - 0.80) * params.bloomAmount * 2.0, 0.0, 0.3);
        color = clamp(color + float3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }

    // ── Pass 10: 胶片颗粒（Film Grain）──────────────────────────────────────
    // grain_intensity=0.28, grain_size=1.8
    // 使用预烘焙噪点纹理 + 时间种子实现动态颗粒
    if (params.grainIntensity > 0.0) {
        // 从噪点纹理采样（UV 乘以 grainSize 控制颗粒大小）
        float2 grainUV = uv * params.grainSize;
        float3 grainSample = grainTexture.sample(s, grainUV).rgb;

        // 时间种子：锁定到 24fps（floor(time*24)/24），避免颗粒闪烁过快
        float timeSeed = floor(params.time * 24.0) / 24.0;
        float dynamicGrain = fqsRandom(uv, timeSeed) - 0.5;

        // 混合纹理颗粒和程序颗粒（7:3）
        float grain = mix(grainSample.r - 0.5, dynamicGrain, 0.3);

        // 颗粒强度随亮度变化：中间调颗粒最明显，高光和阴影减弱
        float grainLum = dot(color, float3(0.2126, 0.7152, 0.0722));
        float grainMask = 1.0 - abs(grainLum - 0.45) * 1.2;
        grainMask = clamp(grainMask, 0.3, 1.0);

        // 彩色颗粒（FQS grain_color=true）：对 RGB 分别加不同颗粒
        float grainR = fqsRandom(uv, timeSeed + 0.1) - 0.5;
        float grainG = fqsRandom(uv, timeSeed + 0.2) - 0.5;
        float grainB = fqsRandom(uv, timeSeed + 0.3) - 0.5;
        float3 colorGrain = float3(grainR, grainG, grainB) * 0.3;  // 色彩颗粒权重
        float3 lumaGrain  = float3(grain);                          // 亮度颗粒

        float3 totalGrain = mix(lumaGrain, colorGrain, 0.4);  // 60% 亮度 + 40% 彩色
        color = clamp(color + totalGrain * params.grainIntensity * 0.22 * grainMask,
                      0.0, 1.0);
    }

    // ── Pass 11: 亮度噪声 + 色度噪声（胶片扫描噪声）────────────────────────
    if (params.luminanceNoise > 0.0) {
        float noise = fqsRandom(uv, params.time * 0.5) - 0.5;
        float darkMask = 1.0 - clamp(lum * 1.5, 0.0, 1.0);  // 暗部噪声更明显
        color = clamp(color + noise * params.luminanceNoise * 0.15 * darkMask, 0.0, 1.0);
    }
    if (params.chromaNoise > 0.0) {
        float3 chromaNoise = float3(
            fqsRandom(uv, params.time * 0.3 + 10.0) - 0.5,
            fqsRandom(uv, params.time * 0.3 + 20.0) - 0.5,
            fqsRandom(uv, params.time * 0.3 + 30.0) - 0.5
        );
        float darkMask = 1.0 - clamp(lum * 2.0, 0.0, 1.0);
        color = clamp(color + chromaNoise * params.chromaNoise * 0.10 * darkMask, 0.0, 1.0);
    }

    // ── Pass 12: 暗角（Vignette）─────────────────────────────────────────────
    if (params.vignetteAmount > 0.0) {
        float vignette = fqsVignette(uv, params.vignetteAmount);
        color *= vignette;
    }

    return float4(color, 1.0);
}
