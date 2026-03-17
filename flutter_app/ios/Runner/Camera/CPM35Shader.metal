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
//   3. Light Grain    — grain_amount=0.16, grain_size=1.6（轻颗粒，干净出片）
//
// 与 FQS 的关键差异：
//   FQS: R-4%, G+5%, B+2% → 偏冷绿（Fuji Superia 风格）
//   CPM35: R+4%, G+2%, B-4% → 偏暖（Kodak Gold 风格）
//   FQS: grain=0.28（明显）    CPM35: grain=0.16（轻）
//   FQS: halation=0.15（高光发红）  CPM35: halation=0.06（克制）
//
// ⚠️  CPM35Params 字段顺序必须与 Swift CCDParams 完全一致（Metal 按内存偏移读取）
// ⚠️  新增字段只能追加到末尾，不能插入中间

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
// ⚠️  字段顺序必须与 Swift CCDParams 完全一致（Metal 按内存偏移读取）

struct CPM35Params {
    // ── 通用参数（与 CCDParams 字段顺序完全相同）────────────────────────────
    float contrast;            // 对比度倍数（CPM35=1.02，比 FQS 的 0.92 略高）
    float saturation;          // 饱和度倍数（CPM35=1.08）
    float temperatureShift;    // 色温偏移（CPM35=+120，暖色）
    float tintShift;           // 色调偏移（CPM35=+4，轻微品红，Kodak 特征）
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     float grainAmount;         // 颗粒强度（CPM35=0.16，比 FQS 轻）
    float noiseAmount;         // 通用噪声量（通用字段，CPM35 不使用）
    float vignetteAmount;      // 暗角强度（CPM35=0.10，比 FQS 轻）
    float chromaticAberration; // 色差强度（CPM35=0.15，比 FQS 克制）
    float bloomAmount;         // 柔光强度（CPM35=0.05）
    float halationAmount;      // 高光暖推强度（CPM35=0.06，克制）
    float sharpen;             // 锐化强度（通用字段）
    float blurRadius;          // 模糊半径（通用字段）
    float jpegArtifacts;       // JPEG 噪点（通用字段）
    float time;                // 时间种子（每帧更新）
    float fisheyeMode;         // 鱼眼模式（通用字段）
    float aspectRatio;         // 宽高比（通用字段）
    // ── CPM35 专用扩展字段（追加在通用字段之后）──────────────────────────────
    float colorBiasR;          // R 通道偏移（CPM35=+0.04，暖红）
    float colorBiasG;          // G 通道偏移（CPM35=+0.02，轻微）
    float colorBiasB;          // B 通道偏移（CPM35=-0.04，压蓝去冷感）
    float grainSize;           // 颗粒大小（CPM35=1.6，比 FQS 细）
    float sharpness;           // 锐度倍数（CPM35=1.04，轻微锐化）
    float highlightWarmAmount; // 暖高光强度（CPM35=0.06）
    float luminanceNoise;      // 亮度噪声（CPM35=0.05）
    float chromaNoise;         // 色度噪声（CPM35=0.03）
    // ── 胶片/数码通用参数（Inst C / SQC / FXN-R / CPM35 共用）──────────────
    float highlightRolloff;    // 高光柔和滴落（CPM35=0.14，Kodak 特征）
// SIMPLIFIED:     float edgeFalloff;         // 边缘曝光衰减（CPM35=0.030）
    float exposureVariation;   // 曝光波动（CPM35=0.018）
// SIMPLIFIED:     float cornerWarmShift;     // 角落偏移（CPM35=+0.022，偏暖橙）
    float centerGain;          // 中心增亮（CPM35=0.015）
// SIMPLIFIED:     float developmentSoftness; // 显影柔化（CPM35=0.028，Kodak 冲洗扩散）
// SIMPLIFIED:     float chemicalIrregularity;// 化学不规则感（CPM35=0.020）
// SIMPLIFIED:     float skinHueProtect;      // 肤色保护开关（CPM35=1.0，开启）
    float skinSatProtect;      // 肤色饱和度保护（CPM35=0.90）
    float skinLumaSoften;      // 肤色亮度柔化（CPM35=0.04）
    float skinRedLimit;        // 肤色红限（CPM35=1.05，防止过橙）
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

    const float x0 = 0.0,       y0 = 0.0;
    const float x1 = 0.12549,   y1 = 0.10196;
    const float x2 = 0.25098,   y2 = 0.23529;
    const float x3 = 0.50196,   y3 = 0.49412;
    const float x4 = 0.75294,   y4 = 0.81569;
    const float x5 = 1.0,       y5 = 0.98824;

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
    c.r = clamp(c.r + ts * 0.018 * strength, 0.0, 1.0);
    c.b = clamp(c.b - ts * 0.022 * strength, 0.0, 1.0);

    float tint = tintShift / 1000.0;
    float midtoneMask = clamp(1.0 - abs(lum - 0.5) * 1.5, 0.0, 1.0);
    c.r = clamp(c.r + tint * 0.006 * midtoneMask, 0.0, 1.0);
    c.b = clamp(c.b + tint * 0.004 * midtoneMask, 0.0, 1.0);

    return c;
}

/// Kodak Gold 暖高光（区别于 FQS 的 Halation 发红）
float3 cpm35HighlightWarmth(float3 c, float amount) {
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    if (lum > 0.55) {
        float warmMask = clamp((lum - 0.55) / 0.45, 0.0, 1.0);
        warmMask = warmMask * warmMask;
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

/// Highlight Rolloff（胶片高光保护，0.14）
float3 cpm35HighlightRolloff(float3 c, float rolloff) {
    if (rolloff <= 0.0) return c;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((lum - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.40;
    return clamp(c * compress, 0.0, 1.0);
}

/// 肤色保护（CPM35 肤色是卖点，防止暖调让肤色过橙）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: // SIMPLIFIED: // SIMPLIFIED: float3 cpm35SkinProtect(float3 c, float skinHueProtect, float skinSatProtect,
                        float skinLumaSoften, float skinRedLimit) {
// SIMPLIFIED:     if (skinHueProtect < 0.5) return c;
    float maxC = max(c.r, max(c.g, c.b));
    float minC = min(c.r, min(c.g, c.b));
    float chroma = maxC - minC;
    if (chroma < 0.05 || maxC < 0.2) return c;
    float hue = 0.0;
    if (maxC == c.r) {
        hue = (c.g - c.b) / chroma;
        if (hue < 0.0) hue += 6.0;
    } else {
        return c;
    }
    float skinMask = clamp(1.0 - abs(hue - 0.4) / 0.8, 0.0, 1.0);
    float lum2 = dot(c, float3(0.2126, 0.7152, 0.0722));
    float3 desatColor = float3(lum2);
    float3 protectedColor = mix(c, desatColor, (1.0 - skinSatProtect) * skinMask);
    protectedColor.r = min(protectedColor.r, lum2 * skinRedLimit);
    if (skinLumaSoften > 0.0) {
        float softLum = lum2 * (1.0 + skinLumaSoften * 0.15);
        protectedColor = mix(protectedColor, protectedColor * (softLum / max(lum2, 0.001)), skinMask * skinLumaSoften);
    }
    return clamp(protectedColor, 0.0, 1.0);
}

/// 传感器非均匀性（35mm 胶片相机，中心增亮+边缘衰减+角落偏暖）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED: float3 cpm35CenterEdge(float3 c, float2 uv, float centerGain, float edgeFalloff,
// SIMPLIFIED:                        float cornerWarmShift, float exposureVariation, float time) {
    float2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
// SIMPLIFIED:     float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    float factor = clamp(center * edge, 0.5, 1.5);
    c = clamp(c * factor, 0.0, 1.0);
// SIMPLIFIED:     if (cornerWarmShift > 0.0) {
        float cornerMask = clamp(dist * dist * 4.0 - 0.5, 0.0, 1.0);
// SIMPLIFIED:         c.r = clamp(c.r + cornerWarmShift * cornerMask * 0.5, 0.0, 1.0);
// SIMPLIFIED:         c.b = clamp(c.b - cornerWarmShift * cornerMask * 0.4, 0.0, 1.0);
    }
    if (exposureVariation > 0.0) {
        float2 blockUV = floor(uv * 8.0) / 8.0;
        float evn = (cpm35Random(blockUV, time * 0.01) - 0.5) * exposureVariation * 0.4;
        c = clamp(c + evn, 0.0, 1.0);
    }
    return c;
}

// MARK: - CPM35 片段着色器

fragment float4 cpm35FragmentShader(
    CPM35VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> grainTexture  [[texture(2)]],
    constant CPM35Params &params   [[buffer(0)]]
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

    // ── Pass 5: 对比度（1.02）────────────────────────────────────────────────
    color = cpm35Contrast(color, params.contrast);

    // ── Pass 6: 色温 + Tint（+120K 暖色，+4 tint 轻微品红）─────────────────
    color = cpm35TemperatureTint(color, params.temperatureShift, params.tintShift);

    // ── Pass 7: Highlight Rolloff（胶片高光保护，0.14）──────────────────────────────
    color = cpm35HighlightRolloff(color, params.highlightRolloff);

    // ── Pass 8: Kodak 暖高光（高光区额外暖推）────────────────────────────────────────────
    color = cpm35HighlightWarmth(color, params.highlightWarmAmount);

    // ── Pass 9: Halation（橙红色，0.07，Kodak 胶片特征）──────────────────────────────────────
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (params.halationAmount > 0.001 && lum > 0.78) {
        float halationMask = clamp((lum - 0.78) / 0.22, 0.0, 1.0);
        halationMask = halationMask * halationMask;
        float3 halationColor = float3(
            color.r * 1.10,   // 橙红色 halation（Kodak 特征）
            color.g * 1.03,
            color.b * 0.88
        );
        color = mix(color, halationColor, halationMask * params.halationAmount * 0.55);
    }

    // ── Pass 10: Bloom（轻柔光，0.05）───────────────────────────────────────────────
    if (params.bloomAmount > 0.001 && lum > 0.82) {
        float bloom = clamp((lum - 0.82) * params.bloomAmount * 2.0, 0.0, 0.2);
        // Leica 镜头 bloom 偏暖白
        color = clamp(color + float3(bloom * 0.95, bloom * 0.80, bloom * 0.60), 0.0, 1.0);
    }

    // ── Pass 11: 肤色保护（skinRedLimit=1.05，防止肤色过橙）─────────────────────────────────────
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: // SIMPLIFIED: // SIMPLIFIED:     color = cpm35SkinProtect(color, params.skinHueProtect, params.skinSatProtect,
                             params.skinLumaSoften, params.skinRedLimit);

// SIMPLIFIED:     // ── Pass 12: 传感器非均匀性（centerGain+edgeFalloff+cornerWarmShift）──────────────────────────────
// PREVIEW_SIMPLIFIED: // SIMPLIFIED:     color = cpm35CenterEdge(color, uv, params.centerGain, params.edgeFalloff,
// SIMPLIFIED:                             params.cornerWarmShift, params.exposureVariation, params.time);

// SIMPLIFIED:     // ── Pass 13: 显影柔化（developmentSoftness=0.028，Kodak 冲洗扩散）────────────────────────────────
// SIMPLIFIED:     if (params.developmentSoftness > 0.0) {
        float2 ts = float2(1.0 / 1080.0, 1.0 / 1440.0);
        float3 s1 = cameraTexture.sample(s, uv + float2(ts.x, 0.0)).rgb;
        float3 s2 = cameraTexture.sample(s, uv - float2(ts.x, 0.0)).rgb;
        float3 s3 = cameraTexture.sample(s, uv + float2(0.0, ts.y)).rgb;
        float3 s4 = cameraTexture.sample(s, uv - float2(0.0, ts.y)).rgb;
        float3 blurred = (s1 + s2 + s3 + s4) * 0.25;
        blurred.r = cpm35ToneCurve(blurred.r) * (1.0 + params.colorBiasR);
        blurred.g = cpm35ToneCurve(blurred.g) * (1.0 + params.colorBiasG);
        blurred.b = cpm35ToneCurve(blurred.b) * (1.0 + params.colorBiasB);
// SIMPLIFIED:         color = mix(color, blurred, params.developmentSoftness);
        color = clamp(color, 0.0, 1.0);
    }

    // ── Pass 14: 胶片颗粒（Film Grain，彩色颗粒 30%）──────────────────────────────────────────
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     if (params.grainAmount > 0.001) {
        float2 grainUV = uv * max(params.grainSize, 0.1);
        float3 grainSample = grainTexture.sample(s, grainUV).rgb;

        float timeSeed = floor(params.time * 24.0) / 24.0;
        float dynamicGrain = cpm35Random(uv, timeSeed) - 0.5;
        float grain = mix(grainSample.r - 0.5, dynamicGrain, 0.3);

        float grainLum = dot(color, float3(0.2126, 0.7152, 0.0722));
        float grainMask = clamp(1.0 - abs(grainLum - 0.45) * 1.2, 0.3, 1.0);

        float3 colorGrain = float3(
            cpm35Random(uv, timeSeed + 0.1) - 0.5,
            cpm35Random(uv, timeSeed + 0.2) - 0.5,
            cpm35Random(uv, timeSeed + 0.3) - 0.5
        ) * 0.25;
        float3 lumaGrain = float3(grain);
        float3 totalGrain = mix(lumaGrain, colorGrain, 0.3);  // 70% 亮度 + 30% 彩色

// SIMPLIFIED_PREVIEW: // SIMPLIFIED:         color = clamp(color + totalGrain * params.grainAmount * 0.22 * grainMask,
                      0.0, 1.0);
    }

    // ── Pass 11: 亮度噪声 + 色度噪声（轻扫描噪声）──────────────────────────
    if (params.luminanceNoise > 0.001) {
        float noise = cpm35Random(uv, params.time * 0.5) - 0.5;
        float darkMask = 1.0 - clamp(lum * 1.5, 0.0, 1.0);
        color = clamp(color + noise * params.luminanceNoise * 0.15 * darkMask, 0.0, 1.0);
    }
    if (params.chromaNoise > 0.001) {
        float3 cn = float3(
            cpm35Random(uv, params.time * 0.3 + 10.0) - 0.5,
            cpm35Random(uv, params.time * 0.3 + 20.0) - 0.5,
            cpm35Random(uv, params.time * 0.3 + 30.0) - 0.5
        );
        float darkMask = 1.0 - clamp(lum * 2.0, 0.0, 1.0);
        color = clamp(color + cn * params.chromaNoise * 0.10 * darkMask, 0.0, 1.0);
    }

    // ── Pass 12: 暗角（Vignette，0.10）──────────────────────────────────────
    if (params.vignetteAmount > 0.001) {
        color *= cpm35Vignette(uv, params.vignetteAmount);
    }

    return float4(color, 1.0);
}
