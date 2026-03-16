// CCDRShader.metal
// DAZZ — CCD R (2003-2006 早期 CCD 数码相机，冷蓝绿调) Metal Shader
//
// ═══════════════════════════════════════════════════════════════════════════
// 风格定位：
//   Sony Cyber-shot DSC-T 系列 / Canon IXUS 早期型号（2003-2006）
//   核心气质：冷蓝绿 + CCD 彩色噪声 + 高光 bloom 溢出 + 早期数码味
//
// 核心特征（基于 2003-2006 早期 CCD 传感器真实特性）：
//   1. 冷蓝绿色调（temperature=-15，早期 CCD 白平衡算法偏冷）
//   2. R 通道压暗（colorBiasR=-0.030，偏冷非暖）
//   3. B 通道增强（colorBiasB=+0.048，天空极蓝）
//   4. G 通道偏青（colorBiasG=+0.018，早期 CCD 青绿偏向）
//   5. 强彩色噪声（chromaNoise=0.08，早期 CCD 传感器标志特征）
//   6. 强 bloom（bloom=0.12，CCD 高光溢出特征）
//   7. 低 highlightRolloff（0.06，CCD 高光保护差，允许略溢）
//   8. 阴影提亮（shadows=+6，CCD 宽容度低，厂商补偿）
//   9. 廉价镜头色差（chromaticAberration=0.11）
//  10. 肤色保护（skinRedLimit=1.02，防止冷 LUT 削红让肤色发青）
//
// GPU Pipeline 顺序（14 pass）：
//   Camera Frame
//   → Pass 0: 色差（早期廉价镜头，0.11）
//   → Pass 1: 白平衡（冷蓝绿，temperature=-15）
//   → Pass 2: Highlight Rolloff（低保护，允许高光略溢，0.06）
//   → Pass 3: 早期 CCD Tone Curve（阴影提亮+高光快速溢出）
//   → Pass 4: RGB 通道倾向（R-0.030, G+0.018, B+0.048）
//   → Pass 5: 对比度 + 饱和度
//   → Pass 6: CCD Bloom + Halation（高光 bloom 强）
//   → Pass 7: 肤色保护（防止冷 LUT 让肤色发青）
//   → Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减 + 冷角）
//   → Pass 9: 传感器热噪声（chemicalIrregularity=0.008）
//   → Pass 10: 亮度噪声（luminanceNoise=0.08）
//   → Pass 11: 彩色噪声（chromaNoise=0.08，早期 CCD 标志）
//   → Pass 12: 颗粒（grain=0.22, grainSize=1.3）
//   → Pass 13: 暗角（vignette=0.12）
//   → Output
// ═══════════════════════════════════════════════════════════════════════════

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// ── CCDRParams 结构体（与 Swift 端 CCDParams 字段顺序一致）────────────────
struct CCDRParams {
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
    float colorBiasR;
    float colorBiasG;
    float colorBiasB;
    float grainSize;
    float sharpness;
    float highlightWarmAmount;
    float luminanceNoise;
    float chromaNoise;
    float highlightRolloff;
    float paperTexture;
    float edgeFalloff;
    float exposureVariation;
    float cornerWarmShift;
    float centerGain;
    float developmentSoftness;
    float chemicalIrregularity;
    float skinHueProtect;
    float skinSatProtect;
    float skinLumaSoften;
    float skinRedLimit;
};

vertex VertexOut ccdrVertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// ── 工具函数 ──────────────────────────────────────────────────────────────

static float ccdrRandom(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

static float3 ccdrWhiteBalance(float3 c, float tempShift, float tintShift) {
    float t = tempShift / 1000.0;
    float g = tintShift / 1000.0;
    c.r = clamp(c.r + t * 0.3, 0.0, 1.0);
    c.b = clamp(c.b - t * 0.3, 0.0, 1.0);
    c.g = clamp(c.g + g * 0.2, 0.0, 1.0);
    return c;
}

/// 早期 CCD Tone Curve
/// 特点：黑位轻提（CCD 黑位不纯）+ 阴影明显提亮（宽容度低补偿）
///       + 中间调平 + 高光快速溢出（CCD 高光保护差）
/// 控制点：
///   Input:  0      0.063  0.251  0.502  0.627  0.878  1.0
///   Output: 0.020  0.085  0.270  0.510  0.660  0.940  1.0
static float ccdrToneCurve(float x) {
    const float inp[7]  = {0.0,   0.063, 0.251, 0.502, 0.627, 0.878, 1.0};
    const float outp[7] = {0.020, 0.085, 0.270, 0.510, 0.660, 0.940, 1.0};
    for (int i = 0; i < 6; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outp[i], outp[i + 1], t);
        }
    }
    return outp[6];
}

static float3 ccdrContrast(float3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

static float3 ccdrSaturation(float3 c, float sat) {
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(lum), c, sat), 0.0, 1.0);
}

/// Highlight Rolloff（低保护，允许 CCD 高光略溢）
static float3 ccdrHighlightRolloff(float3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.25; // 比胶片更低，允许溢出
    return clamp(color * compress, 0.0, 1.0);
}

/// CCD Bloom（强，0.12）+ Halation（偏冷蓝白）
static float3 ccdrBloomHalation(float3 color, float bloom, float halation) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 result = color;
    if (bloom > 0.0) {
        float h = clamp((luma - 0.70) / 0.30, 0.0, 1.0);
        // CCD bloom 偏冷白（不是暖橙）
        float3 bloomColor = float3(0.85, 0.92, 1.0);
        result = clamp(result + bloomColor * h * bloom * 0.5, 0.0, 1.0);
    }
    if (halation > 0.0) {
        float h = clamp((luma - 0.80) / 0.20, 0.0, 1.0);
        // CCD halation 偏蓝紫（早期 CCD 传感器特征）
        float3 halationColor = float3(0.7, 0.8, 1.0);
        result = clamp(result + halationColor * h * halation * 0.3, 0.0, 1.0);
    }
    return result;
}

/// 肤色保护（防止冷 LUT 让肤色发青）
static float3 ccdrSkinProtect(float3 color, float protect,
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
    // 肤色色相范围（0.03-0.12，偏橙粉）
    float skinMask = smoothstep(0.030, 0.065, h) * (1.0 - smoothstep(0.100, 0.140, h));
    if (skinMask < 0.001) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 prot = mix(float3(luma), color, satProt);
    prot = clamp(prot + lumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, redLimit);
    return mix(color, prot, skinMask);
}

/// 传感器非均匀性（中心增亮 + 边缘衰减）
static float ccdrCenterEdge(float2 uv, float centerGain, float edgeFalloff) {
    float2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

/// 角落偏冷（cornerWarmShift 为负值时偏冷蓝，CCD R 特征）
static float3 ccdrCornerShift(float2 uv, float3 color, float shift) {
    float2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor; // 负值=偏冷蓝
    color.r = clamp(color.r + s * 0.5, 0.0, 1.0);
    color.g = clamp(color.g + s * 0.2, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.3, 0.0, 1.0); // shift 为负时 b 增加
    return color;
}

static float ccdrVignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── Fragment Shader ───────────────────────────────────────────────────────
fragment float4 ccdrFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    constant CCDRParams& p [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.texCoord;
    float2 ts = float2(1.0 / 1080.0, 1.0 / 1440.0);

    // === Pass 0: 色差（早期廉价镜头，0.11）===
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

    // === Pass 1: 白平衡（冷蓝绿，temperature=-15）===
    color = ccdrWhiteBalance(color, p.temperatureShift, p.tintShift);

    // === Pass 2: Highlight Rolloff（低保护，允许高光略溢，0.06）===
    color = ccdrHighlightRolloff(color, p.highlightRolloff);

    // === Pass 3: 早期 CCD Tone Curve（阴影提亮+高光快速溢出）===
    color.r = ccdrToneCurve(color.r);
    color.g = ccdrToneCurve(color.g);
    color.b = ccdrToneCurve(color.b);

    // === Pass 4: RGB 通道倾向（R-0.030, G+0.018, B+0.048）===
    color.r = clamp(color.r + p.colorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + p.colorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + p.colorBiasB, 0.0, 1.0);

    // === Pass 5: 对比度 + 饱和度（contrast=0.98, sat=1.10）===
    color = ccdrContrast(color, p.contrast);
    color = ccdrSaturation(color, p.saturation);

    // === Pass 6: CCD Bloom + Halation（高光 bloom 强，冷白/蓝紫）===
    color = ccdrBloomHalation(color, p.bloomAmount, p.halationAmount);

    // === Pass 7: 肤色保护（防止冷 LUT 让肤色发青）===
    color = ccdrSkinProtect(color,
        p.skinHueProtect, p.skinSatProtect,
        p.skinLumaSoften, p.skinRedLimit);

    // === Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减 + 冷角）===
    if (p.centerGain > 0.0 || p.edgeFalloff > 0.0) {
        float factor = ccdrCenterEdge(uv, p.centerGain, p.edgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    if (p.exposureVariation > 0.0) {
        float evn = ccdrRandom(uv * 0.1, p.time * 0.01) - 0.5;
        color = clamp(color + evn * p.exposureVariation * 0.3, 0.0, 1.0);
    }
    // cornerWarmShift 为负值 = 偏冷蓝
    color = ccdrCornerShift(uv, color, p.cornerWarmShift);

    // === Pass 9: 传感器热噪声（chemicalIrregularity=0.008）===
    if (p.chemicalIrregularity > 0.0) {
        float2 blockUV = floor(uv * 32.0) / 32.0; // 更大的块，模拟热噪声
        float irr = (ccdrRandom(blockUV, 0.77) - 0.5) * p.chemicalIrregularity;
        color = clamp(color + irr * 0.5, 0.0, 1.0);
    }

    // === Pass 10: 亮度噪声（luminanceNoise=0.08）===
    if (p.luminanceNoise > 0.0) {
        float2 lnUV = uv / max(p.grainSize * 0.003, 0.001);
        float ln = (ccdrRandom(lnUV, floor(p.time * 30.0) / 30.0) - 0.5);
        // 暗部噪声更明显（早期 CCD 暗部噪声特征）
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float darkBoost = 1.0 + (1.0 - luma) * 1.2;
        color = clamp(color + ln * p.luminanceNoise * 0.2 * darkBoost, 0.0, 1.0);
    }

    // === Pass 11: 彩色噪声（chromaNoise=0.08，早期 CCD 标志特征）===
    if (p.chromaNoise > 0.0) {
        float2 cnUV = uv / max(p.grainSize * 0.004, 0.001);
        // 早期 CCD 彩色噪声偏蓝绿（与 CCD R 色调一致）
        float cr = (ccdrRandom(cnUV, 1.1) - 0.5) * p.chromaNoise * 0.10;
        float cg = (ccdrRandom(cnUV, 2.3) - 0.5) * p.chromaNoise * 0.14; // G 噪声略强
        float cb = (ccdrRandom(cnUV, 3.7) - 0.5) * p.chromaNoise * 0.16; // B 噪声最强
        color = clamp(color + float3(cr, cg, cb), 0.0, 1.0);
    }

    // === Pass 12: 颗粒（grain=0.22, grainSize=1.3）===
    if (p.grainAmount > 0.0) {
        float2 grainUV = uv / max(p.grainSize * 0.003, 0.001);
        float grain = ccdrRandom(grainUV, floor(p.time * 30.0) / 30.0) - 0.5;
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float darkBoost = 1.0 + (1.0 - luma) * 0.6;
        color = clamp(color + grain * p.grainAmount * 0.22 * darkBoost, 0.0, 1.0);
    }

    // === Pass 13: 暗角（vignette=0.12）===
    if (p.vignetteAmount > 0.0) {
        color *= ccdrVignette(uv, p.vignetteAmount);
    }

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
