// U300Shader.metal
// DAZZ — U300 (Kodak UltraMax 400 一次性胶卷相机) Metal Shader
//
// ═══════════════════════════════════════════════════════════════════════════
// 风格定位：
//   Kodak UltraMax 400 + Kodak FunSaver 一次性胶卷相机
//   核心气质：暖橙 + 粗颗粒 + 胶片高光 + Kodak 肤色
//
// 核心特征（基于 Kodak UltraMax 400 真实胶片特性）：
//   1. 暖橙色调（temperature=40，Kodak 标志性暖黄橙）
//   2. R 通道偏强（colorBiasR=+0.055，Kodak 红色饱满）
//   3. B 通道压暗（colorBiasB=-0.045，天空偏暖非冷蓝）
//   4. 粗颗粒（grain=0.22, grainSize=1.5，400 度胶片）
//   5. 彩色噪声（chromaNoise=0.06，Kodak 400 特征）
//   6. 胶片高光 rolloff（highlightRolloff=0.15，比数码更明显）
//   7. 化学显影柔化（developmentSoftness=0.03）
//   8. 化学不规则感（chemicalIrregularity=0.025）
//   9. 廉价镜头色差（chromaticAberration=0.09）
//  10. 肤色保护（skinRedLimit=1.05，防止 Kodak 肤色过橙）
//
// GPU Pipeline 顺序（14 pass）：
//   Camera Frame
//   → Pass 0: 色差（廉价镜头，0.09）
//   → Pass 1: 白平衡（暖橙，temperature=40）
//   → Pass 2: Highlight Rolloff（胶片高光保护，0.15）
//   → Pass 3: Kodak Tone Curve（正片感曲线）
//   → Pass 4: RGB 通道倾向（R+0.055, G+0.018, B-0.045）
//   → Pass 5: 对比度 + 饱和度
//   → Pass 6: 胶片 Halation（极轻，0.03）
//   → Pass 7: 肤色保护（防止 Kodak 肤色过橙）
//   → Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减）
//   → Pass 9: 化学显影柔化（developmentSoftness=0.03）
//   → Pass 10: 化学不规则感（chemicalIrregularity=0.025）
//   → Pass 11: 粗颗粒（grain=0.22, grainSize=1.5）
//   → Pass 12: 彩色噪声（chromaNoise=0.06）
//   → Pass 13: 暗角（vignette=0.16）
//   → Output
// ═══════════════════════════════════════════════════════════════════════════

#include <metal_stdlib>
using namespace metal;

// ── 顶点着色器输入/输出 ───────────────────────────────────────────────────
struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// ── U300Params 结构体（与 Swift 端 CCDParams 字段顺序一致）────────────────
struct U300Params {
    float contrast;
    float saturation;
    float temperatureShift;
    float tintShift;
    float grainAmount;
    float noiseAmount;
    float vignetteAmount;
    float chromaticAberration;
    float bloomAmount;
    float halationAmount;
    float sharpen;
    float blurRadius;
    float jpegArtifacts;
    float time;
    float fisheyeMode;
    float aspectRatio;
    // ── 通道偏移 ──────────────────────────────────────────────────────────
    float colorBiasR;
    float colorBiasG;
    float colorBiasB;
    float grainSize;
    float sharpness;
    float highlightWarmAmount;
    float luminanceNoise;
    float chromaNoise;
    // ── 胶片专属参数 ──────────────────────────────────────────────────────
    float highlightRolloff;
    float paperTexture;
    float edgeFalloff;
    float exposureVariation;
    float cornerWarmShift;
    // ── 胶片/拍立得通用参数 ───────────────────────────────────────────────
    float centerGain;
    float developmentSoftness;
    float chemicalIrregularity;
    float skinHueProtect;
    float skinSatProtect;
    float skinLumaSoften;
    float skinRedLimit;
};

// ── 顶点着色器 ────────────────────────────────────────────────────────────
vertex VertexOut u300VertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// ── 工具函数 ──────────────────────────────────────────────────────────────

/// 伪随机数（基于 UV + 时间种子）
static float u300Random(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// 白平衡（色温 + 色调）
static float3 u300WhiteBalance(float3 c, float tempShift, float tintShift) {
    float t = tempShift / 1000.0;
    float g = tintShift / 1000.0;
    c.r = clamp(c.r + t * 0.3, 0.0, 1.0);
    c.b = clamp(c.b - t * 0.3, 0.0, 1.0);
    c.g = clamp(c.g + g * 0.2, 0.0, 1.0);
    return c;
}

/// Kodak UltraMax 400 Tone Curve（正片感曲线）
/// 控制点（归一化）：
///   Input:  0      0.063  0.125  0.251  0.502  0.627  0.878  1.0
///   Output: 0      0.047  0.110  0.235  0.518  0.680  0.910  0.975
/// 特点：阴影轻压 + 中间调轻提 + 高光亮但不溢（Kodak 正片感）
static float u300ToneCurve(float x) {
    const float inp[8] = {0.0, 0.063, 0.125, 0.251, 0.502, 0.627, 0.878, 1.0};
    const float outp[8] = {0.0, 0.047, 0.110, 0.235, 0.518, 0.680, 0.910, 0.975};
    for (int i = 0; i < 7; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outp[i], outp[i + 1], t);
        }
    }
    return outp[7];
}

/// 对比度
static float3 u300Contrast(float3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度
static float3 u300Saturation(float3 c, float sat) {
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(lum), c, sat), 0.0, 1.0);
}

/// Highlight Rolloff（胶片高光保护）
static float3 u300HighlightRolloff(float3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.35;
    return clamp(color * compress, 0.0, 1.0);
}

/// Halation（胶片高光发光，极轻）
static float3 u300Halation(float3 color, float amount) {
    if (amount <= 0.0) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float highlight = clamp((luma - 0.75) / 0.25, 0.0, 1.0);
    // Kodak halation 偏橙红
    float3 halationColor = float3(1.0, 0.55, 0.2);
    return clamp(color + halationColor * highlight * amount * 0.4, 0.0, 1.0);
}

/// 肤色保护（防止 Kodak 暖调让肤色过橙）
static float3 u300SkinProtect(float3 color, float protect,
                               float satProt, float lumaSoften, float redLimit) {
    if (protect < 0.5) return color;
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
    // 肤色色相范围（偏橙：0.03-0.12）
    float skinMask = smoothstep(0.030, 0.065, h) * (1.0 - smoothstep(0.100, 0.140, h));
    if (skinMask < 0.001) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 prot = mix(float3(luma), color, satProt);
    prot = clamp(prot + lumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, redLimit);
    return mix(color, prot, skinMask);
}

/// 传感器非均匀性（中心增亮 + 边缘衰减）
static float u300CenterEdge(float2 uv, float centerGain, float edgeFalloff) {
    float2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

/// 角落偏暖（Kodak 边角暖橙特征）
static float3 u300CornerWarm(float2 uv, float3 color, float shift) {
    float2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor;
    color.r = clamp(color.r + s * 0.5, 0.0, 1.0);
    color.g = clamp(color.g + s * 0.2, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.3, 0.0, 1.0);
    return color;
}

/// 化学显影柔化（胶片冲洗扩散）
static float3 u300DevelopmentSoften(float2 uv, texture2d<float> tex,
                                     sampler smp, float softness) {
    if (softness <= 0.0) return tex.sample(smp, uv).rgb;
    float2 ts = float2(1.0 / 1080.0, 1.0 / 1440.0);
    float3 blurred =
        tex.sample(smp, uv + float2(-ts.x, 0.0)).rgb * 0.25 +
        tex.sample(smp, uv + float2( ts.x, 0.0)).rgb * 0.25 +
        tex.sample(smp, uv + float2(0.0, -ts.y)).rgb * 0.25 +
        tex.sample(smp, uv + float2(0.0,  ts.y)).rgb * 0.25;
    float3 color = tex.sample(smp, uv).rgb;
    return mix(color, blurred, softness * 0.5);
}

/// 暗角
static float u300Vignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── Fragment Shader ───────────────────────────────────────────────────────
fragment float4 u300FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    constant U300Params& p [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.texCoord;
    float2 ts = float2(1.0 / 1080.0, 1.0 / 1440.0);

    // === Pass 0: 色差（廉价镜头，0.09）===
    float3 color;
    if (p.chromaticAberration > 0.0) {
        float ca = p.chromaticAberration * ts.x * 20.0;
        float r = cameraTexture.sample(s, uv + float2(ca, 0.0)).r;
        float g = cameraTexture.sample(s, uv).g;
        float b = cameraTexture.sample(s, uv - float2(ca, 0.0)).b;
        color = float3(r, g, b);
    } else {
        color = cameraTexture.sample(s, uv).rgb;
    }

    // === Pass 1: 白平衡（暖橙，temperature=40）===
    color = u300WhiteBalance(color, p.temperatureShift, p.tintShift);

    // === Pass 2: Highlight Rolloff（胶片高光保护，0.15）===
    color = u300HighlightRolloff(color, p.highlightRolloff);

    // === Pass 3: Kodak Tone Curve（正片感曲线）===
    color.r = u300ToneCurve(color.r);
    color.g = u300ToneCurve(color.g);
    color.b = u300ToneCurve(color.b);

    // === Pass 4: RGB 通道倾向（R+0.055, G+0.018, B-0.045）===
    color.r = clamp(color.r + p.colorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + p.colorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + p.colorBiasB, 0.0, 1.0);

    // === Pass 5: 对比度 + 饱和度（contrast=0.96, sat=1.10）===
    color = u300Contrast(color, p.contrast);
    color = u300Saturation(color, p.saturation);

    // === Pass 6: 胶片 Halation（极轻，0.03）===
    color = u300Halation(color, p.halationAmount);

    // === Pass 7: 肤色保护（防止 Kodak 肤色过橙）===
    color = u300SkinProtect(color,
        p.skinHueProtect, p.skinSatProtect,
        p.skinLumaSoften, p.skinRedLimit);

    // === Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减）===
    if (p.centerGain > 0.0 || p.edgeFalloff > 0.0) {
        float factor = u300CenterEdge(uv, p.centerGain, p.edgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    if (p.exposureVariation > 0.0) {
        float evn = u300Random(uv * 0.1, p.time * 0.01) - 0.5;
        color = clamp(color + evn * p.exposureVariation * 0.3, 0.0, 1.0);
    }
    if (p.cornerWarmShift > 0.0) {
        color = u300CornerWarm(uv, color, p.cornerWarmShift);
    }

    // === Pass 9: 化学显影柔化（developmentSoftness=0.03）===
    if (p.developmentSoftness > 0.0) {
        color = u300DevelopmentSoften(uv, cameraTexture, s, p.developmentSoftness);
    }

    // === Pass 10: 化学不规则感（chemicalIrregularity=0.025）===
    if (p.chemicalIrregularity > 0.0) {
        float2 blockUV = floor(uv * 64.0) / 64.0;
        float irr = (u300Random(blockUV, 0.42) - 0.5) * p.chemicalIrregularity;
        color = clamp(color + irr * 0.6, 0.0, 1.0);
    }

    // === Pass 11: 粗颗粒（grain=0.22, grainSize=1.5）===
    if (p.grainAmount > 0.0) {
        float2 grainUV = uv / max(p.grainSize * 0.003, 0.001);
        float grain = u300Random(grainUV, floor(p.time * 24.0) / 24.0) - 0.5;
        // 暗部颗粒更明显（Kodak 400 特征）
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float darkBoost = 1.0 + (1.0 - luma) * 0.8;
        color = clamp(color + grain * p.grainAmount * 0.25 * darkBoost, 0.0, 1.0);
    }

    // === Pass 12: 彩色噪声（chromaNoise=0.06，Kodak 400 特征）===
    if (p.chromaNoise > 0.0) {
        float2 cnUV = uv / max(p.grainSize * 0.004, 0.001);
        float cr = (u300Random(cnUV, 1.1) - 0.5) * p.chromaNoise * 0.15;
        float cg = (u300Random(cnUV, 2.3) - 0.5) * p.chromaNoise * 0.10;
        float cb = (u300Random(cnUV, 3.7) - 0.5) * p.chromaNoise * 0.12;
        color = clamp(color + float3(cr, cg, cb), 0.0, 1.0);
    }

    // === Pass 13: 暗角（vignette=0.16）===
    if (p.vignetteAmount > 0.0) {
        color *= u300Vignette(uv, p.vignetteAmount);
    }

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
