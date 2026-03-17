// GRDRShader.metal
// DAZZ Camera — GRD-R (Ricoh GR Digital Street Photography)
//
// Pipeline 顺序（专属，区别于通用 CCD shader）：
//   Camera Frame
//   → Pass 0: Unsharp Mask 锐化（高锐度，Ricoh GR 标志）
//   → Pass 1: 色差（极轻微，0.05）
//   → Pass 2: 白平衡（冷静，temperature=-20）
//   → Pass 3: Highlight Rolloff（高光保护，0.10）
//   → Pass 4: GRD-R Tone Curve（微对比曲线，阴影压+中间调清晰）
//   → Pass 5: RGB 通道倾向（R-0.02, B+0.02）
//   → Pass 6: 对比度 + 饱和度（contrast=1.10, sat=0.92）
//   → Pass 7: Clarity / 微对比（clarity=8，GRD-R 灵魂）
//   → Pass 8: 肤色保护（防止低饱和让脸发灰）
//   → Pass 9: 传感器非均匀性（极低，数码相机）
//   → Pass 10: 传感器噪声（luminanceNoise=0.06，无色度噪声）
//   → Pass 11: 暗角（极轻微，0.05）
//   → Output
//
// 设计原则（GRD-R 复刻三要素）：
//   1. 高锐度    — sharpen=0.12, sharpness=1.12, clarity=8
//   2. 冷中性    — temperature=-20, colorBiasB=+0.02
//   3. 微对比    — Tone Curve 阴影压暗+中间调清晰，contrast=1.10
//
// ⚠️  GRDRParams 字段顺序必须与 Swift CCDParams 完全一致（Metal 按内存偏移读取）
// ⚠️  新增字段只能追加到末尾，不能插入中间
#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点着色器
struct GRDRVertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct GRDRVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex GRDRVertexOut grdrVertexShader(GRDRVertexIn in [[stage_in]]) {
    GRDRVertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// MARK: - GRDRParams Uniform 参数
// ⚠️  字段顺序与 Swift CCDParams 完全一致，不可修改顺序
struct GRDRParams {
    // ── 通用参数（与 CCDParams 字段顺序完全相同）────────────────────────────
    float contrast;            // 对比度倍数（GRD-R=1.10）
    float saturation;          // 饱和度倍数（GRD-R=0.92）
    float temperatureShift;    // 色温偏移（GRD-R=-20）
    float tintShift;           // 色调偏移（GRD-R=-2）
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     float grainAmount;         // 颗粒强度（GRD-R=0.08）
    float noiseAmount;         // 通用噪声量（GRD-R 不使用）
    float vignetteAmount;      // 暗角强度（GRD-R=0.05）
    float chromaticAberration; // 色差强度（GRD-R=0.05）
    float bloomAmount;         // 柔光强度（GRD-R=0.02）
    float halationAmount;      // 高光发光（GRD-R=0.00）
    float sharpen;             // 锐化强度（GRD-R=0.12）
    float blurRadius;          // 模糊半径（GRD-R 不使用）
    float jpegArtifacts;       // JPEG 噪点（GRD-R 不使用）
    float time;                // 时间种子（动态颗粒）
    float fisheyeMode;         // 鱼眼模式（GRD-R 不使用）
    float aspectRatio;         // 宽高比
    // ── FQS/CPM35 扩展字段（GRD-R 使用 colorBiasR/G/B 和 grainSize）────────
    float colorBiasR;          // R 通道偏移（GRD-R=-0.02）
    float colorBiasG;          // G 通道偏移（GRD-R=0.00）
    float colorBiasB;          // B 通道偏移（GRD-R=+0.02）
    float grainSize;           // 颗粒大小（GRD-R=1.2）
    float sharpness;           // 锐度倍数（GRD-R=1.12）
    float highlightWarmAmount; // 暖高光（GRD-R 不使用）
    float luminanceNoise;      // 亮度噪声（GRD-R=0.06，传感器风格）
    float chromaNoise;         // 色度噪声（GRD-R=0.00）
    // ── Inst C 扩展字段（GRD-R 使用 highlightRolloff）────────────────────────
    float highlightRolloff;    // 高光柔和滚落（GRD-R=0.10）
// SIMPLIFIED:     float paperTexture;        // 相纸纹理（GRD-R 不使用）
// SIMPLIFIED:     float edgeFalloff;         // 边缘衰减（GRD-R=0.015）
    float exposureVariation;   // 曝光波动（GRD-R=0.010）
// SIMPLIFIED:     float cornerWarmShift;     // 角落色温（GRD-R=-0.005）
    // ── 拍立得/数码通用扩展字段（GRD-R 使用 centerGain + skin protect）────────
    float centerGain;          // 中心增亮（GRD-R=0.005）
// SIMPLIFIED:     float developmentSoftness; // 显影柔化（GRD-R=0.000）
// SIMPLIFIED:     float chemicalIrregularity;// 化学不规则（GRD-R=0.000）
// SIMPLIFIED:     float skinHueProtect;      // 肤色保护（GRD-R=1.0）
    float skinSatProtect;      // 肤色饱和度保护（GRD-R=0.95）
    float skinLumaSoften;      // 肤色亮度柔化（GRD-R=0.02）
    float skinRedLimit;        // 肤色红限（GRD-R=1.03）
};

// MARK: - 工具函数

/// 伪随机数生成
float grdrRandom(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// GRD-R Tone Curve（微对比曲线）
/// 控制点（归一化）：
///   Input:  0    16   32   64   96   128  160  192  224  255
///   Output: 0    10   22   50   90   132  180  215  240  255
/// 特点：阴影压暗（-6）+ 中间调微提（+4）+ 高光干净
float grdrToneCurve(float x) {
    // 归一化控制点
    const float inp[10] = {0.0, 0.0627, 0.1255, 0.2510, 0.3765,
                           0.5020, 0.6275, 0.7529, 0.8784, 1.0};
    const float out[10] = {0.0, 0.0392, 0.0863, 0.1961, 0.3529,
                           0.5176, 0.7059, 0.8431, 0.9412, 1.0};
    for (int i = 0; i < 9; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(out[i], out[i + 1], t);
        }
    }
    return out[9];
}

/// 白平衡（色温 + 色调）
float3 grdrWhiteBalance(float3 color, float tempShift, float tintShift) {
    float t = tempShift / 1000.0;
    float g = tintShift / 1000.0;
    color.r = clamp(color.r + t * 0.3, 0.0, 1.0);
    color.b = clamp(color.b - t * 0.3, 0.0, 1.0);
    color.g = clamp(color.g + g * 0.2, 0.0, 1.0);
    return color;
}

/// 对比度
float3 grdrContrast(float3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度
float3 grdrSaturation(float3 c, float sat) {
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(lum), c, sat), 0.0, 1.0);
}

/// Clarity / 微对比（局部对比度增强）
/// 原理：用大半径模糊提取低频，与原图差值放大中频细节
float3 grdrClarity(float3 color, float2 uv, texture2d<float> tex, sampler s,
                   float2 texelSize, float clarityAmount) {
    if (clarityAmount <= 0.0) return color;
    // 大半径模糊（5x5 近似）
    float3 blur = float3(0.0);
    float weight = 0.0;
    for (int dx = -2; dx <= 2; dx++) {
        for (int dy = -2; dy <= 2; dy++) {
            float w = 1.0 / (1.0 + abs(float(dx)) + abs(float(dy)));
            blur += tex.sample(s, uv + float2(dx, dy) * texelSize * 3.0).rgb * w;
            weight += w;
        }
    }
    blur /= weight;
    // 微对比 = 原图 + 放大的中频差值
    float3 detail = color - blur;
    return clamp(color + detail * clarityAmount * 0.15, 0.0, 1.0);
}

/// 高光柔和滚落
float3 grdrHighlightRolloff(float3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.3;
    return clamp(color * compress, 0.0, 1.0);
}

/// 肤色保护（GRD-R 低饱和容易让脸发灰）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: // SIMPLIFIED: float3 grdrSkinProtect(float3 color, float protect, float satProt,
                       float lumaSoften, float redLimit) {
    if (protect < 0.5) return color;
    // RGB → HSL
    float maxC = max(max(color.r, color.g), color.b);
    float minC = min(min(color.r, color.g), color.b);
    float delta = maxC - minC;
    float h = 0.0;
    if (delta > 0.001) {
        if (maxC == color.r)      h = fmod((color.g - color.b) / delta, 6.0);
        else if (maxC == color.g) h = (color.b - color.r) / delta + 2.0;
        else                      h = (color.r - color.g) / delta + 4.0;
        h = h / 6.0;
        if (h < 0.0) h += 1.0;
    }
    // 肤色色相范围：0.0356~0.145（约 13°~52°）
    float skinMask = smoothstep(0.0356, 0.0756, h) * (1.0 - smoothstep(0.105, 0.145, h));
    if (skinMask < 0.001) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 prot = mix(float3(luma), color, satProt);
    prot = clamp(prot + lumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, redLimit);
    return mix(color, prot, skinMask);
}

/// 传感器非均匀性（中心增亮 + 边缘衰减）
// SIMPLIFIED: float grdrCenterEdge(float2 uv, float centerGain, float edgeFalloff) {
    float2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
// SIMPLIFIED:     float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

/// 角落色温偏移（GRD-R=-0.005，极轻微偏冷）
float3 grdrCornerWarm(float2 uv, float3 color, float shift) {
    float2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor;
    color.r = clamp(color.r + s * 0.4, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.4, 0.0, 1.0);
    return color;
}

/// Unsharp Mask 锐化（3x3 高斯）
float3 grdrSharpen(float2 uv, texture2d<float> tex, sampler s,
                   float2 texelSize, float amount) {
    float3 center = tex.sample(s, uv).rgb;
    if (amount <= 0.0) return center;
    float3 blur =
        tex.sample(s, uv + float2(-texelSize.x, -texelSize.y)).rgb * 1.0 +
        tex.sample(s, uv + float2( 0.0,         -texelSize.y)).rgb * 2.0 +
        tex.sample(s, uv + float2( texelSize.x, -texelSize.y)).rgb * 1.0 +
        tex.sample(s, uv + float2(-texelSize.x,  0.0        )).rgb * 2.0 +
        center                                                       * 4.0 +
        tex.sample(s, uv + float2( texelSize.x,  0.0        )).rgb * 2.0 +
        tex.sample(s, uv + float2(-texelSize.x,  texelSize.y)).rgb * 1.0 +
        tex.sample(s, uv + float2( 0.0,          texelSize.y)).rgb * 2.0 +
        tex.sample(s, uv + float2( texelSize.x,  texelSize.y)).rgb * 1.0;
    blur /= 16.0;
    return clamp(center + amount * 2.0 * (center - blur), 0.0, 1.0);
}

/// 暗角
float grdrVignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// MARK: - Fragment Shader

fragment float4 grdrFragmentShader(
    GRDRVertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    constant GRDRParams& params [[buffer(0)]],
    constant float2& texelSize [[buffer(1)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float2 uv = in.texCoord;

    // === Pass 0: Unsharp Mask 锐化（Ricoh GR 高锐度标志）===
    // sharpen=0.12，比 FXN-R 高 3 倍，是 GRD-R 最重要的特征之一
    float3 color = grdrSharpen(uv, cameraTexture, texSampler, texelSize, params.sharpen);

    // === Pass 1: 色差（极轻微，0.05）===
    // Ricoh GR 28mm 镜头色差极低，仅保留轻微数码感
    if (params.chromaticAberration > 0.0) {
        float ca = params.chromaticAberration * texelSize.x * 20.0;
        float r = cameraTexture.sample(texSampler, uv + float2(ca, 0.0)).r;
        float g = cameraTexture.sample(texSampler, uv).g;
        float b = cameraTexture.sample(texSampler, uv - float2(ca, 0.0)).b;
        color = float3(r, g, b);
    }

    // === Pass 2: 白平衡（冷静，temperature=-20）===
    color = grdrWhiteBalance(color, params.temperatureShift, params.tintShift);

    // === Pass 3: Highlight Rolloff（高光保护，0.10）===
    // GRD-R 高光干净，轻微保护防止过曝失真
    if (params.highlightRolloff > 0.0) {
        color = grdrHighlightRolloff(color, params.highlightRolloff);
    }

    // === Pass 4: GRD-R Tone Curve（微对比曲线，GRD-R 灵魂）===
    // 阴影压暗（-6）+ 中间调清晰 + 高光干净
    // 这是 Ricoh GR 街拍质感的核心
    float3 curved;
    curved.r = grdrToneCurve(color.r);
    curved.g = grdrToneCurve(color.g);
    curved.b = grdrToneCurve(color.b);
    color = curved;

    // === Pass 5: RGB 通道倾向（冷静偏蓝）===
    // R-0.02, G±0, B+0.02 → 整体冷静，不偏暖
    color.r = clamp(color.r + params.colorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + params.colorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + params.colorBiasB, 0.0, 1.0);

    // === Pass 6: 对比度 + 饱和度（contrast=1.10, sat=0.92）===
    color = grdrContrast(color, params.contrast);
    color = grdrSaturation(color, params.saturation);

    // === Pass 7: Clarity / 微对比（clarity=8，GRD-R 灵魂之二）===
    // 局部对比度增强，让街拍细节更锐利
    // clarityAmount 从 JSON 的 clarity=8 映射到 0~1（除以 100）
    float clarityNorm = 8.0 / 100.0;
    color = grdrClarity(color, uv, cameraTexture, texSampler, texelSize, clarityNorm);

    // === Pass 8: 肤色保护（防止低饱和让脸发灰）===
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: // SIMPLIFIED:     color = grdrSkinProtect(color,
// SIMPLIFIED:         params.skinHueProtect, params.skinSatProtect,
        params.skinLumaSoften, params.skinRedLimit);

    // === Pass 9: 传感器非均匀性（极低，数码相机）===
// SIMPLIFIED:     if (params.centerGain > 0.0 || params.edgeFalloff > 0.0) {
// SIMPLIFIED:         float factor = grdrCenterEdge(uv, params.centerGain, params.edgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    if (params.exposureVariation > 0.0) {
        float evn = grdrRandom(uv * 0.1, params.time * 0.01) - 0.5;
        color = clamp(color + evn * params.exposureVariation * 0.3, 0.0, 1.0);
    }
// SIMPLIFIED:     if (params.cornerWarmShift != 0.0) {
// SIMPLIFIED:         color = grdrCornerWarm(uv, color, params.cornerWarmShift);
    }

    // === Pass 10: 传感器噪声（luminanceNoise=0.06，无色度噪声）===
    // GRD-R 的颗粒更像传感器噪声，不是胶片颗粒
    // 亮度噪声：细腻、均匀
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     if (params.grainAmount > 0.0) {
        float grain = grdrRandom(uv / max(params.grainSize, 0.1),
                                 floor(params.time * 24.0) / 24.0) - 0.5;
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:         color = clamp(color + grain * params.grainAmount * 0.2, 0.0, 1.0);
    }
    if (params.luminanceNoise > 0.0) {
        float ln = grdrRandom(uv, params.time + 1.7) - 0.5;
        color = clamp(color + ln * params.luminanceNoise * 0.12, 0.0, 1.0);
    }
    // chromaNoise=0.00，GRD-R 无色度噪声（数码相机干净）

    // === Pass 11: 暗角（极轻微，0.05）===
    // Ricoh GR 28mm 暗角极低
    if (params.vignetteAmount > 0.0) {
        color *= grdrVignette(uv, params.vignetteAmount);
    }

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
