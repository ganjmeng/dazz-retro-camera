// BWClassicShader.metal
// DAZZ — BW Classic (Kodak Tri-X 400 / Ilford HP5 Plus 35mm 黑白胶片) Metal Shader
//
// ═══════════════════════════════════════════════════════════════════════════
// 风格定位：
//   Kodak Tri-X 400 / Ilford HP5 Plus（35mm 黑白胶片，高对比经典）
//   核心气质：深黑 + 高对比 + 粗颗粒 + 银盐光晕 + 真实胶片层次
//
// 核心特征（基于 Kodak Tri-X 400 真实感光特性）：
//   1. 黑白混合通道权重（Channel Mixer）
//      bwChannelR=0.22（红色权重偏低，肤色偏暗，Tri-X 特征）
//      bwChannelG=0.72（绿色权重偏高，主要亮度来源）
//      bwChannelB=0.06（蓝色权重偏低，天空深暗，云彩对比强）
//   2. 高对比（contrast=1.28，Tri-X 标志特征）
//   3. 深黑（shadows=-20, blacks=-28，Tri-X 深黑特征）
//   4. 粗颗粒（grain=0.26, grainSize=1.4，比彩色胶片更粗）
//   5. 银盐光晕（bloom=0.04，高光区域银粒扩散，冷白色）
//   6. 强 Tone Curve（阴影深压+高光干净+中间调清晰）
//   7. 显影柔化（developmentSoftness=0.025，D-76 显影液扩散）
//   8. 明显暗角（vignette=0.18，35mm 相机特征）
//   9. 无色差（chromaticAberration=0.0，黑白胶片无色差）
//  10. 无肤色保护（黑白模式，skinHueProtect=0.0）
//
// GPU Pipeline 顺序（12 pass）：
//   Camera Frame
//   → Pass 0: 黑白混合（Channel Mixer，Tri-X 感光特性权重）
//   → Pass 1: Tone Curve（深黑+高光干净+中间调微对比）
//   → Pass 2: 对比度（contrast=1.28）
//   → Pass 3: Clarity 微对比（局部对比度，clarity=14）
//   → Pass 4: Highlight Rolloff（胶片高光保护，0.18）
//   → Pass 5: 银盐光晕（bloom=0.04，冷白银盐扩散）
//   → Pass 6: 传感器非均匀性（中心增亮+边缘衰减）
//   → Pass 7: 显影柔化（developmentSoftness=0.025）
//   → Pass 8: 化学不规则感（chemicalIrregularity=0.018）
//   → Pass 9: 亮度噪声（luminanceNoise=0.04）
//   → Pass 10: 粗颗粒（grain=0.26, grainSize=1.4，暗部增强）
//   → Pass 11: 暗角（vignette=0.18）
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

// ── BWClassicParams 结构体（与 Swift 端 CCDParams 字段顺序一致）──────────────
struct BWClassicParams {
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
    // BW Classic 专用字段
    float bwChannelR;   // 红色通道权重（Tri-X=0.22，偏低）
    float bwChannelG;   // 绿色通道权重（Tri-X=0.72，偏高）
    float bwChannelB;   // 蓝色通道权重（Tri-X=0.06，偏低）
    float clarity;      // Clarity 微对比强度
    float toneCurveStrength;
};

vertex VertexOut bwClassicVertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// ── 工具函数 ──────────────────────────────────────────────────────────────

static float bwRandom(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// Kodak Tri-X 400 Tone Curve（黑白胶片特征曲线）
/// 特点：深黑（阴影强压）+ 中间调微对比 + 高光干净不溢
/// 控制点（归一化 0-1）：
///   Input:  0      0.063  0.125  0.251  0.502  0.627  0.878  1.0
///   Output: 0.000  0.020  0.060  0.175  0.490  0.640  0.920  1.0
static float bwToneCurve(float x) {
    const float inp[8]  = {0.0,   0.063, 0.125, 0.251, 0.502, 0.627, 0.878, 1.0};
    const float outp[8] = {0.000, 0.020, 0.060, 0.175, 0.490, 0.640, 0.920, 1.0};
    for (int i = 0; i < 7; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outp[i], outp[i + 1], t);
        }
    }
    return outp[7];
}

/// Clarity 微对比（局部对比度增强，模拟 Tri-X 质感）
static float bwClarity(float luma, float clarity) {
    if (clarity <= 0.0) return luma;
    // S 形曲线增强中间调对比
    float mid = 0.5;
    float delta = luma - mid;
    float boost = delta * clarity * 0.015;
    return clamp(luma + boost, 0.0, 1.0);
}

/// Highlight Rolloff（胶片高光保护，0.18）
static float bwHighlightRolloff(float luma, float rolloff) {
    if (rolloff <= 0.0) return luma;
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.45; // 胶片高光保护比数码更强
    return clamp(luma * compress, 0.0, 1.0);
}

/// 银盐光晕（bloom=0.04，高光区域银粒扩散，冷白色）
static float bwSilverBloom(float luma, float bloom) {
    if (bloom <= 0.0) return luma;
    float h = clamp((luma - 0.78) / 0.22, 0.0, 1.0);
    return clamp(luma + h * bloom * 0.6, 0.0, 1.0);
}

/// 传感器非均匀性（35mm 相机，中心增亮+边缘衰减）
static float bwCenterEdge(float2 uv, float centerGain, float edgeFalloff) {
    float2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

static float bwVignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── Fragment Shader ───────────────────────────────────────────────────────
fragment float4 bwClassicFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    constant BWClassicParams& p [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.texCoord;

    // 采样原始彩色图像
    float3 colorIn = cameraTexture.sample(s, uv).rgb;

    // === Pass 0: 黑白混合（Channel Mixer，Tri-X 感光特性权重）===
    // Tri-X 400: R=0.22（红色不敏感，肤色偏暗），G=0.72，B=0.06（天空深暗）
    float bwR = p.bwChannelR > 0.0 ? p.bwChannelR : 0.22;
    float bwG = p.bwChannelG > 0.0 ? p.bwChannelG : 0.72;
    float bwB = p.bwChannelB > 0.0 ? p.bwChannelB : 0.06;
    // 归一化权重（确保总和为 1.0）
    float bwSum = bwR + bwG + bwB;
    if (bwSum > 0.001) { bwR /= bwSum; bwG /= bwSum; bwB /= bwSum; }
    float luma = dot(colorIn, float3(bwR, bwG, bwB));
    float3 color = float3(luma);

    // === Pass 1: Tone Curve（深黑+高光干净+中间调微对比）===
    luma = bwToneCurve(luma);
    color = float3(luma);

    // === Pass 2: 对比度（contrast=1.28）===
    luma = clamp((luma - 0.5) * p.contrast + 0.5, 0.0, 1.0);
    color = float3(luma);

    // === Pass 3: Clarity 微对比（clarity=14）===
    luma = bwClarity(luma, p.clarity);
    color = float3(luma);

    // === Pass 4: Highlight Rolloff（胶片高光保护，0.18）===
    luma = bwHighlightRolloff(luma, p.highlightRolloff);
    color = float3(luma);

    // === Pass 5: 银盐光晕（bloom=0.04，冷白银盐扩散）===
    luma = bwSilverBloom(luma, p.bloomAmount);
    color = float3(luma);

    // === Pass 6: 传感器非均匀性（中心增亮+边缘衰减）===
    if (p.centerGain > 0.0 || p.edgeFalloff > 0.0) {
        float factor = bwCenterEdge(uv, p.centerGain, p.edgeFalloff);
        luma = clamp(luma * factor, 0.0, 1.0);
    }
    if (p.exposureVariation > 0.0) {
        float evn = bwRandom(uv * 0.1, p.time * 0.01) - 0.5;
        luma = clamp(luma + evn * p.exposureVariation * 0.3, 0.0, 1.0);
    }
    color = float3(luma);

    // === Pass 7: 显影柔化（developmentSoftness=0.025，D-76 显影液扩散）===
    if (p.developmentSoftness > 0.0) {
        float2 ts = float2(1.0 / 1080.0, 1.0 / 1440.0);
        float s1 = cameraTexture.sample(s, uv + float2(ts.x, 0.0)).r;
        float s2 = cameraTexture.sample(s, uv - float2(ts.x, 0.0)).r;
        float s3 = cameraTexture.sample(s, uv + float2(0.0, ts.y)).r;
        float s4 = cameraTexture.sample(s, uv - float2(0.0, ts.y)).r;
        // 邻域亮度（用原始彩色转灰度）
        float n1 = dot(float3(s1), float3(bwR, bwG, bwB));
        float n2 = dot(float3(s2), float3(bwR, bwG, bwB));
        float n3 = dot(float3(s3), float3(bwR, bwG, bwB));
        float n4 = dot(float3(s4), float3(bwR, bwG, bwB));
        float blurred = (n1 + n2 + n3 + n4) * 0.25;
        luma = mix(luma, blurred, p.developmentSoftness);
        color = float3(luma);
    }

    // === Pass 8: 化学不规则感（chemicalIrregularity=0.018，胶片冲洗批次差异）===
    if (p.chemicalIrregularity > 0.0) {
        float2 blockUV = floor(uv * 24.0) / 24.0;
        float irr = (bwRandom(blockUV, 0.55) - 0.5) * p.chemicalIrregularity;
        luma = clamp(luma + irr * 0.6, 0.0, 1.0);
        color = float3(luma);
    }

    // === Pass 9: 亮度噪声（luminanceNoise=0.04，胶片显影残留）===
    if (p.luminanceNoise > 0.0) {
        float2 lnUV = uv / max(p.grainSize * 0.003, 0.001);
        float ln = (bwRandom(lnUV, floor(p.time * 30.0) / 30.0 + 0.5) - 0.5);
        float darkBoost = 1.0 + (1.0 - luma) * 0.8;
        luma = clamp(luma + ln * p.luminanceNoise * 0.2 * darkBoost, 0.0, 1.0);
        color = float3(luma);
    }

    // === Pass 10: 粗颗粒（grain=0.26, grainSize=1.4，暗部增强 2x）===
    if (p.grainAmount > 0.0) {
        float2 grainUV = uv / max(p.grainSize * 0.003, 0.001);
        float grain = bwRandom(grainUV, floor(p.time * 30.0) / 30.0) - 0.5;
        // Tri-X 颗粒在暗部更明显（暗部颗粒是亮部的 2 倍）
        float darkBoost = 1.0 + (1.0 - luma) * 1.0;
        luma = clamp(luma + grain * p.grainAmount * 0.28 * darkBoost, 0.0, 1.0);
        color = float3(luma);
    }

    // === Pass 11: 暗角（vignette=0.18，35mm 相机明显暗角）===
    if (p.vignetteAmount > 0.0) {
        luma *= bwVignette(uv, p.vignetteAmount);
        color = float3(luma);
    }

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
