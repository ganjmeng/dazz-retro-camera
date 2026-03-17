// FQSShader.metal
// DAZZ Camera — FQS (Fuji Superia 400 + Kodak Portra 400)
//
// Pipeline 顺序：
//   Camera Frame → Chromatic Aberration → Tone Curve → RGB Channel Shift
//   → Saturation → Contrast → Temperature/Tint → Skin Tone Guard
//   → Halation → Bloom → Film Grain → Luma/Chroma Noise → Vignette → Output
//
// 设计原则（FQS 复刻三要素）：
//   1. Fuji Green Tone  — G+5%, 中间调微绿
//   2. Soft Contrast    — 胶片曲线压低阴影、抬高中间调
// SIMPLIFIED_PREVIEW: // SIMPLIFIED: //   3. Film Grain       — grainAmount=0.28, grainSize=1.8
//
// ⚠️  FQSParams 字段顺序必须与 Swift CCDParams 完全一致（Metal 按内存偏移读取）
// ⚠️  新增字段只能追加到末尾，不能插入中间

#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点着色器

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
// ⚠️  字段顺序与 Swift CCDParams 完全一致，不可修改顺序

struct FQSParams {
    // ── 通用参数（与 CCDParams 字段顺序完全相同）────────────────────────────
    float contrast;            // 对比度倍数（FQS=0.92）
    float saturation;          // 饱和度倍数（FQS=1.05）
    float temperatureShift;    // 色温偏移（FQS=-40）
    float tintShift;           // 色调偏移（FQS=-18，偏绿）
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     float grainAmount;         // 颗粒强度（FQS=0.28）
    float noiseAmount;         // 通用噪声量（通用字段，FQS 不使用）
    float vignetteAmount;      // 暗角强度（FQS=0.15）
    float chromaticAberration; // 色差强度（FQS=0.4）
    float bloomAmount;         // 柔光强度（FQS=0.10）
    float halationAmount;      // 高光发光强度（FQS=0.15）
    float sharpen;             // 锐化强度（通用字段）
    float blurRadius;          // 模糊半径（通用字段，FQS 不使用）
    float jpegArtifacts;       // JPEG 噪点（通用字段，FQS 不使用）
    float time;                // 时间种子（每帧更新，使颗粒动态变化）
    float fisheyeMode;         // 鱼眼模式（通用字段，FQS 不使用）
    float aspectRatio;         // 宽高比（通用字段）
    // ── FQS 专用扩展字段（追加在通用字段之后）──────────────────────────────
    float colorBiasR;          // R 通道偏移（FQS=-0.04）
    float colorBiasG;          // G 通道偏移（FQS=+0.05）
    float colorBiasB;          // B 通道偏移（FQS=+0.02）
    float grainSize;           // 颗粒大小（FQS=1.8）
    float sharpness;           // 锐度倍数（FQS=0.85，<1 柔化）
    float highlightWarmAmount; // 暖高光（FQS=0.0，CPM35=0.06）
    float luminanceNoise;      // 亮度噪声（FQS=0.08）
    float chromaNoise;         // 色度噪声（FQS=0.05）
    // ── 胶片/数码通用参数（Inst C / SQC / FXN-R / FQS / CPM35 共用）──────────
    float highlightRolloff;    // 胶片高光柔和滴落（FQS=0.12）
// SIMPLIFIED:     float edgeFalloff;         // 边缘衰减（FQS=0.040）
    float exposureVariation;   // 曝光波动（FQS=0.022）
// SIMPLIFIED:     float cornerWarmShift;     // 角落偏移（FQS=-0.008，负值偏冷）
    float centerGain;          // 中心增亮（FQS=0.018）
// SIMPLIFIED:     float developmentSoftness; // 显影柔化（FQS=0.032）
// SIMPLIFIED:     float chemicalIrregularity;// 化学不规则感（FQS=0.022）
// SIMPLIFIED:     float skinHueProtect;      // 肤色保护开关（FQS=1.0）
    float skinSatProtect;      // 肤色饱和度保护（FQS=0.93）
    float skinLumaSoften;      // 肤色亮度柔化（FQS=0.035）
    float skinRedLimit;        // 肤色红限（FQS=1.01）
};

// MARK: - 工具函数

/// 伪随机数生成（基于 UV + 时间种子）
float fqsRandom(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// FQS 胶片 Tone Curve（分段三次平滑插值）
/// 控制点（归一化）：(0,0) (0.125,0.110) (0.251,0.227) (0.502,0.471) (0.753,0.804) (1,1)
/// 对应原始值：0→0, 32→28, 64→58, 128→120, 192→205, 255→255
float fqsToneCurve(float v) {
    v = clamp(v, 0.0, 1.0);

    const float x0 = 0.0,       y0 = 0.0;
    const float x1 = 0.12549,   y1 = 0.10980;
    const float x2 = 0.25098,   y2 = 0.22745;
    const float x3 = 0.50196,   y3 = 0.47059;
    const float x4 = 0.75294,   y4 = 0.80392;
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

/// 色温 + Tint 偏移（RGB 空间近似）
/// 正值 = 偏暖（加R减B），负值 = 偏冷（减R加B）；tintShift < 0 → 偏绿（G增）
float3 fqsTemperatureTint(float3 c, float tempShift, float tintShift) {
    float ts = tempShift / 1000.0;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    float strength = lum * 0.8 + 0.2;  // 阴影区域减弱偏移
    c.r = clamp(c.r + ts *  0.018 * strength, 0.0, 1.0);
    c.b = clamp(c.b - ts *  0.022 * strength, 0.0, 1.0);

    float tint = tintShift / 1000.0;
    float midtoneMask = 1.0 - abs(lum - 0.5) * 1.5;
    midtoneMask = clamp(midtoneMask, 0.0, 1.0);
    c.g = clamp(c.g + tint * -0.008 * midtoneMask, 0.0, 1.0);

    return c;
}

/// Kodak Portra 肤色保护（防止绿偏破坏肤色）
float3 fqsSkinToneGuard(float3 c) {
    float skinMask = 0.0;
    if (c.r > c.g && c.g > c.b && (c.r - c.b) > 0.08) {
        skinMask = clamp((c.r - c.b - 0.08) * 3.0, 0.0, 1.0);
    }
    c.r = clamp(c.r + skinMask * 0.012, 0.0, 1.0);
    c.g = clamp(c.g + skinMask * 0.004, 0.0, 1.0);
    return c;
}

/// 暗角效果
float fqsVignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

/// Highlight Rolloff（胶片高光柔和滚落，防止硬过曝）
float3 fqsHighlightRolloff(float3 c, float rolloff) {
    if (rolloff < 0.001) return c;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float mask = clamp((lum - threshold) / rolloff, 0.0, 1.0);
    mask = mask * mask * (3.0 - 2.0 * mask); // smoothstep
    float3 compressed = c * (threshold / max(lum, 0.001));
    return mix(c, compressed, mask * 0.65);
}

/// 传感器非均匀性（中心增亮 + 边缘衰减 + 角落色温偏移）
float3 fqsSensorVariation(float3 c, float2 uv,
// SIMPLIFIED:                            float centerGain, float edgeFalloff,
// SIMPLIFIED:                            float exposureVariation, float cornerWarmShift,
                           float time) {
    float2 d = uv - 0.5;
    float r2 = dot(d, d);
    // 中心增亮
    float center = 1.0 + centerGain * (1.0 - r2 * 4.0);
    // 边缘衰减
// SIMPLIFIED:     float edge = 1.0 - edgeFalloff * r2 * 3.5;
    // 曝光波动（低频噪声模拟）
    float variation = 1.0 + exposureVariation * (fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.3;
    c *= clamp(center * edge * variation, 0.6, 1.4);
    // 角落色温偏移（负值=偏冷青，正值=偏暖橙）
    float cornerMask = clamp(r2 * 4.0 - 0.5, 0.0, 1.0);
// SIMPLIFIED:     c.r = clamp(c.r + cornerWarmShift * cornerMask * 0.8, 0.0, 1.0);
// SIMPLIFIED:     c.b = clamp(c.b - cornerWarmShift * cornerMask * 1.0, 0.0, 1.0);
    return c;
}

/// 显影柔化（胶片冲洗扩散感）
float3 fqsDevelopmentSoften(float3 c, float2 uv, float softness,
                             texture2d<float> tex, sampler s) {
    if (softness < 0.001) return c;
    float offset = softness * 0.004;
    float3 blur = float3(0.0);
    blur += tex.sample(s, uv + float2( offset,  0.0)).rgb;
    blur += tex.sample(s, uv + float2(-offset,  0.0)).rgb;
    blur += tex.sample(s, uv + float2( 0.0,  offset)).rgb;
    blur += tex.sample(s, uv + float2( 0.0, -offset)).rgb;
    blur /= 4.0;
    return mix(c, blur, softness * 0.35);
}

/// 肤色保护（防止冷绿 LUT 让肤色发青）
float3 fqsSkinProtect(float3 c, float hueProtect, float satProtect,
                       float lumaSoften, float redLimit) {
    if (hueProtect < 0.5) return c;
    // 肤色检测：R > G > B，且 R-B > 0.08
    float skinMask = 0.0;
    if (c.r > c.g && c.g > c.b && (c.r - c.b) > 0.08) {
        skinMask = clamp((c.r - c.b - 0.08) / 0.25, 0.0, 1.0);
        skinMask *= clamp(c.r * 1.5, 0.0, 1.0); // 亮部更强
    }
    if (skinMask < 0.001) return c;
    // 饱和度保护（防止过饱和）
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    float3 desatColor = float3(lum);
    c = mix(c, mix(c, desatColor, 1.0 - satProtect), skinMask);
    // 亮度柔化（肤色发光感）
    c = clamp(c + skinMask * lumaSoften * 0.08, 0.0, 1.0);
    // 红限（防止肤色过红变橙）
    c.r = clamp(c.r, 0.0, lum * redLimit);
    return c;
}

// MARK: - FQS 片段着色器

fragment float4 fqsFragmentShader(
    FQSVertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> grainTexture  [[texture(2)]],
    constant FQSParams &params     [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    float2 uv = in.texCoord;

    // ── Pass 1: 色差 (Chromatic Aberration) ─────────────────────────────────
    float3 color;
    if (params.chromaticAberration > 0.001) {
        float ca = params.chromaticAberration * 0.01;
        float r = cameraTexture.sample(s, uv + float2(ca,  0.0)).r;
        float g = cameraTexture.sample(s, uv).g;
        float b = cameraTexture.sample(s, uv - float2(ca,  0.0)).b;
        color = float3(r, g, b);
    } else {
        color = cameraTexture.sample(s, uv).rgb;
    }

        // ── Pass 1.5: 显影柔化（胶片冲洗扩散，在曲线前应用）──────────────
// SIMPLIFIED:     color = fqsDevelopmentSoften(color, uv, params.developmentSoftness, cameraTexture, s);

    // ── Pass 2: Tone Curve（胶片曲线，分通道应用保留色偏）──────────────
    color.r = fqsToneCurve(color.r);
    color.g = fqsToneCurve(color.g);
    color.b = fqsToneCurve(color.b);

    // ── Pass 3: RGB Channel Shift（Fuji Superia 色偏）─────────────────────────
    // R×0.96（colorBiasR=-0.04）, G×1.05（colorBiasG=+0.05）, B×1.02（colorBiasB=+0.02）
    color.r = clamp(color.r * (1.0 + params.colorBiasR), 0.0, 1.0);
    color.g = clamp(color.g * (1.0 + params.colorBiasG), 0.0, 1.0);
    color.b = clamp(color.b * (1.0 + params.colorBiasB), 0.0, 1.0);

    // ── Pass 4: 饱和度（1.05）────────────────────────────────────────────────
    color = fqsSaturation(color, params.saturation);

    // ── Pass 5: 对比度（0.92，低对比胶片感）─────────────────────────────────
    color = fqsContrast(color, params.contrast);

      // ── Pass 6: 色温 + Tint（-40K, -18 tint）────────────────────
    color = fqsTemperatureTint(color, params.temperatureShift, params.tintShift);

    // ── Pass 6.5: Highlight Rolloff（胶片高光柔和滴落）────────────────
    color = fqsHighlightRolloff(color, params.highlightRolloff);

    // ── Pass 7: 肤色保护（防止冷绿 LUT 让肤色发青）────────────────
// SIMPLIFIED:     color = fqsSkinProtect(color, params.skinHueProtect, params.skinSatProtect,
                           params.skinLumaSoften, params.skinRedLimit);

    // ── Pass 8: Highlight Halation（高光发光，模拟胶片高光溢出）──────────────
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (params.halationAmount > 0.001 && lum > 0.75) {
        float halationMask = clamp((lum - 0.75) / 0.25, 0.0, 1.0);
        halationMask = halationMask * halationMask;
        // Halation 颜色：偏暖红（胶片高光发红）
        float3 halationColor = float3(
            color.r * 1.15,
            color.g * 0.95,
            color.b * 0.80
        );
        color = mix(color, halationColor, halationMask * params.halationAmount);
    }

    // ── Pass 9: Bloom（柔光）─────────────────────────────────────────────────
    if (params.bloomAmount > 0.001 && lum > 0.80) {
        float bloom = clamp((lum - 0.80) * params.bloomAmount * 2.0, 0.0, 0.3);
        color = clamp(color + float3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }

    // ── Pass 10: 胶片颗粒（Film Grain）──────────────────────────────────────
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     if (params.grainAmount > 0.001) {
        // 时间种子锁定到 24fps，避免颗粒闪烁过快
        float timeSeed = floor(params.time * 24.0) / 24.0;

        // 从噪点纹理采样（grainSize 控制颗粒大小）
        float2 grainUV = uv * max(params.grainSize, 0.1);
        float3 grainSample = grainTexture.sample(s, grainUV).rgb;
        float dynamicGrain = fqsRandom(uv, timeSeed) - 0.5;

        // 混合纹理颗粒和程序颗粒（7:3）
        float grain = mix(grainSample.r - 0.5, dynamicGrain, 0.3);

        // 颗粒强度随亮度变化：中间调最明显，高光和阴影减弱
        float grainLum = dot(color, float3(0.2126, 0.7152, 0.0722));
        float grainMask = 1.0 - abs(grainLum - 0.45) * 1.2;
        grainMask = clamp(grainMask, 0.3, 1.0);

        // 彩色颗粒（grain_color=true）：对 RGB 分别加不同颗粒
        float3 colorGrain = float3(
            fqsRandom(uv, timeSeed + 0.1) - 0.5,
            fqsRandom(uv, timeSeed + 0.2) - 0.5,
            fqsRandom(uv, timeSeed + 0.3) - 0.5
        ) * 0.3;
        float3 lumaGrain = float3(grain);
        float3 totalGrain = mix(lumaGrain, colorGrain, 0.4);  // 60% 亮度 + 40% 彩色

// SIMPLIFIED_PREVIEW: // SIMPLIFIED:         color = clamp(color + totalGrain * params.grainAmount * 0.22 * grainMask,
                      0.0, 1.0);
    }

    // ── Pass 11: 亮度噪声 + 色度噪声（胶片扫描噪声）────────────────────────
    if (params.luminanceNoise > 0.001) {
        float noise = fqsRandom(uv, params.time * 0.5) - 0.5;
        float darkMask = 1.0 - clamp(lum * 1.5, 0.0, 1.0);
        color = clamp(color + noise * params.luminanceNoise * 0.15 * darkMask, 0.0, 1.0);
    }
    if (params.chromaNoise > 0.001) {
        float3 cn = float3(
            fqsRandom(uv, params.time * 0.3 + 10.0) - 0.5,
            fqsRandom(uv, params.time * 0.3 + 20.0) - 0.5,
            fqsRandom(uv, params.time * 0.3 + 30.0) - 0.5
        );
        float darkMask = 1.0 - clamp(lum * 2.0, 0.0, 1.0);
        color = clamp(color + cn * params.chromaNoise * 0.10 * darkMask, 0.0, 1.0);
    }

      // ── Pass 11.5: 传感器非均匀性（中心增亮 + 边缘衰减 + 角落色温）────────────
    color = fqsSensorVariation(color, uv,
// SIMPLIFIED:                                params.centerGain, params.edgeFalloff,
// SIMPLIFIED:                                params.exposureVariation, params.cornerWarmShift,
                               params.time);

    // ── Pass 12: 暗角（Vignette）───────────────────────────────────────────
    if (params.vignetteAmount > 0.001) {
        color *= fqsVignette(uv, params.vignetteAmount);
    }

    return float4(color, 1.0);
}
