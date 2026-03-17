// SQCShader.metal
// DAZZ Camera — SQC (Instax Square 升级版)
//
// ═══════════════════════════════════════════════════════════════════════════
// 风格定位：
//   Fujifilm Instax Square 升级版 preset
//   高于 Inst C 的饱和度、亮度、暖粉感、闪光感、中心主体感
//   肤色保护、不均匀曝光、显影柔化、化学不规则感
//
// 核心特征：
//   1. 高饱和（saturation=1.18）
//   2. 整体提亮（brightness=+0.06）
//   3. 更明显暖粉感（temperature=+15，tint=+18）
//   4. 更强闪光感（bloom=0.14，halation=0.06）
//   5. 中心主体感（centerGain=0.03）
// SIMPLIFIED: //   6. 肤色保护（skinHueProtect=true）
//   7. 显影柔化 + 化学不规则感
//
// GPU Pipeline 顺序（19 Pass）：
//   Camera Frame
//   → Chromatic Aberration（轻色差）
//   → White Balance（+15 暖粉，+18 洋红）
//   → Tone Curve（Instax Square 曲线）
//   → RGB Channel Shift（暖粉色偏）
//   → Brightness Lift（整体提亮）
//   → Saturation（1.18）
//   → Contrast（0.88，低对比闪光感）
//   → Highlight Rolloff（0.28，高光柔和）
//   → Flash Bloom（0.14，闪光感柔光）
//   → Halation（0.06，高光发光）
//   → Center Gain（中心主体增亮）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: //   → Fine Grain（0.06，轻颗粒）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: //   → Paper Texture（0.05）
//   → Skin Tone Protection（肤色保护）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: //   → Edge Falloff / Uneven Exposure（不均匀曝光）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: //   → Development Softness（显影柔化）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: //   → Chemical Irregularity（化学不规则感）
// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW: //   → Corner Warm Shift（边角偏暖）
//   → Vignette（0.04，极轻）
//   → Output
//
// ⚠️  SQCParams 字段顺序必须与 Swift 侧 CCDParams buffer 布局完全一致
// ⚠️  新增字段只能追加到末尾
// ═══════════════════════════════════════════════════════════════════════════

#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点着色器

struct SQCVertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct SQCVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex SQCVertexOut sqcVertexShader(SQCVertexIn in [[stage_in]]) {
    SQCVertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// MARK: - SQC Uniform 参数
/// ⚠️ SQCParams 字段顺序必须与 Swift 侧 CCDParams buffer 布局完全一致
struct SQCParams {
    // ── 通用参数（与 CCDParams 字段顺序完全相同）────────────────────────────
    float contrast;            // 对比度倍数（SQC=0.88）
    float saturation;          // 饱和度倍数（SQC=1.18）
    float temperatureShift;    // 色温偏移（SQC=+15，偏暖粉）
    float tintShift;           // 色调偏移（SQC=+18，洋红粉感）
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     float grainAmount;         // 颗粒强度（SQC=0.06，轻颗粒）
    float noiseAmount;         // 通用噪声量（SQC 不使用）
    float vignetteAmount;      // 暗角强度（SQC=0.04，极轻）
    float chromaticAberration; // 色差强度（SQC=0.03）
    float bloomAmount;         // 柔光强度（SQC=0.14，闪光感）
    float halationAmount;      // 高光发光强度（SQC=0.06）
    float sharpen;             // 锐化（SQC 不使用）
    float blurRadius;          // 模糊半径（SQC 不使用）
    float jpegArtifacts;       // JPEG 噪点（SQC 不使用）
    float time;                // 时间种子（每帧更新）
    float fisheyeMode;         // 鱼眼模式（SQC 不使用）
    float aspectRatio;         // 宽高比
    // ── FQS/CPM35/InstC 共用字段（SQC 使用 colorBias/grainSize/sharpness）─────
    float colorBiasR;          // R 通道偏移（SQC=+0.035，暖红）
    float colorBiasG;          // G 通道偏移（SQC=+0.008，轻绿）
    float colorBiasB;          // B 通道偏移（SQC=-0.025，去蓝暖粉）
    float grainSize;           // 颗粒大小（SQC=1.6）
    float sharpness;           // 锐度倍数（SQC=0.92，略柔化）
    float highlightWarmAmount; // 暖高光推送（SQC 不使用）
    float luminanceNoise;      // 亮度噪声（SQC 不使用）
    float chromaNoise;         // 色度噪声（SQC 不使用）
    // ── Inst C / SQC 共用字段────────────────────────────────────────────────
    float highlightRolloff;    // 高光柔和滴落强度（SQC=0.28）
// SIMPLIFIED:     float paperTexture;        // 相纸纹理强度（SQC=0.05）
// SIMPLIFIED:     float edgeFalloff;         // 边缘曝光衰减（SQC=0.06）
    float exposureVariation;   // 全局曝光不均匀幅度（SQC=0.05）
// SIMPLIFIED:     float cornerWarmShift;     // 边角偏暖强度（SQC=0.03）
    // ── SQC 专用扩展字段（追加在 CCDParams 末尾）────────────────────────────
    float centerGain;          // 中心增亮（主体感，SQC=0.03）
// SIMPLIFIED:     float developmentSoftness; // 显影柔化（SQC=0.04）
// SIMPLIFIED:     float chemicalIrregularity;// 化学不规则感（SQC=0.02）
// SIMPLIFIED:     float skinHueProtect;      // 肤色保护（1.0=开启）
    float skinSatProtect;      // 肤色饱和度保护（SQC=0.95）
    float skinLumaSoften;      // 肤色亮度柔化（SQC=0.04）
    float skinRedLimit;        // 肤色红限（SQC=1.03）
};

// MARK: - 工具函数

/// 伪随机数生成（基于 UV + 时间种子）
float sqcRandom(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// SQC Tone Curve（Instax Square 曲线）
/// 比 Inst C 更亮、更柔，高光更软
/// 控制点：0→8, 32→36, 64→72, 128→134, 192→206, 255→246
float sqcToneCurve(float x) {
    if (x < 0.125) {
        float t = x / 0.125;
        float t2 = t * t, t3 = t2 * t;
        return 0.031 + (0.141 - 0.031) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.251) {
        float t = (x - 0.125) / 0.126;
        float t2 = t * t, t3 = t2 * t;
        return 0.141 + (0.282 - 0.141) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.502) {
        float t = (x - 0.251) / 0.251;
        float t2 = t * t, t3 = t2 * t;
        return 0.282 + (0.525 - 0.282) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.753) {
        float t = (x - 0.502) / 0.251;
        float t2 = t * t, t3 = t2 * t;
        return 0.525 + (0.808 - 0.525) * (3.0 * t2 - 2.0 * t3);
    } else {
        float t = (x - 0.753) / 0.247;
        float t2 = t * t, t3 = t2 * t;
        return 0.808 + (0.965 - 0.808) * (3.0 * t2 - 2.0 * t3);
    }
}

/// SQC 白平衡（正值偏暖，负值偏冷）
float3 sqcWhiteBalance(float3 c, float tempShift, float tintShift) {
    float ts = tempShift / 1000.0;
    float tt = tintShift / 1000.0;
    c.r = clamp(c.r + ts * 0.3 + tt * 0.15, 0.0, 1.0);
    c.g = clamp(c.g - tt * 0.08, 0.0, 1.0);
    c.b = clamp(c.b - ts * 0.3, 0.0, 1.0);
    return c;
}

/// 肤色检测（基于 HSL 色相范围）
/// 皮肤色相范围：约 0°~50°（红橙黄区间）
float sqcSkinMask(float3 c) {
    float maxC = max(c.r, max(c.g, c.b));
    float minC = min(c.r, min(c.g, c.b));
    float delta = maxC - minC;
    if (delta < 0.05 || maxC < 0.15) return 0.0; // 接近黑白，不是肤色
    float hue = 0.0;
    if (maxC == c.r) {
        hue = fmod((c.g - c.b) / delta, 6.0);
    } else if (maxC == c.g) {
        hue = (c.b - c.r) / delta + 2.0;
    } else {
        hue = (c.r - c.g) / delta + 4.0;
    }
    hue = hue / 6.0; // 归一化到 [0, 1]
    if (hue < 0.0) hue += 1.0;
    // 肤色色相范围：0~0.10（红橙）和 0.92~1.0（红）
    float skinRange = 0.0;
    if (hue < 0.10 || hue > 0.92) {
        // 饱和度检查：肤色饱和度适中（不太高不太低）
        float sat = (maxC > 0.0) ? (delta / maxC) : 0.0;
        float lum = (maxC + minC) * 0.5;
        if (sat > 0.10 && sat < 0.75 && lum > 0.25 && lum < 0.85) {
            skinRange = smoothstep(0.0, 0.08, min(hue, 1.0 - hue + 1.0)) *
                        smoothstep(0.0, 0.05, sat - 0.10) *
                        smoothstep(0.0, 0.05, lum - 0.25);
        }
    }
    return clamp(skinRange, 0.0, 1.0);
}

// MARK: - SQC Fragment Shader

fragment float4 sqcFragmentShader(
    SQCVertexOut in [[stage_in]],
    texture2d<float, access::sample> cameraTexture [[texture(0)]],
    constant SQCParams& p [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.texCoord;
    float2 center = float2(0.5, 0.5);
    float2 offset = uv - center;

    // ── Pass 1: Chromatic Aberration ─────────────────────────────────────────
    float ca = p.chromaticAberration * 0.012;
    float2 caOffset = offset * ca;
    float r = cameraTexture.sample(s, uv + caOffset).r;
    float g = cameraTexture.sample(s, uv).g;
    float b = cameraTexture.sample(s, uv - caOffset).b;
    float3 color = float3(r, g, b);

    // ── Pass 2: White Balance（暖粉感核心）──────────────────────────────────
    color = sqcWhiteBalance(color, p.temperatureShift, p.tintShift);

    // ── Pass 3: Tone Curve（Instax Square 曲线）──────────────────────────────
    color.r = sqcToneCurve(color.r);
    color.g = sqcToneCurve(color.g);
    color.b = sqcToneCurve(color.b);

    // ── Pass 4: RGB Channel Shift（暖粉色偏）────────────────────────────────
    color.r = clamp(color.r + p.colorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + p.colorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + p.colorBiasB, 0.0, 1.0);

    // ── Pass 5: Brightness Lift（整体提亮，闪光感）──────────────────────────
    // 亮度提升使用 soft lift（避免高光过曝）
    float brightLift = 0.06;
    color = color + brightLift * (1.0 - color * 0.5);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 6: Saturation（更浓郁色彩）────────────────────────────────────
    float luma6 = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma6), color, p.saturation);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 7: Contrast（低对比，闪光感）──────────────────────────────────
    color = (color - 0.5) * p.contrast + 0.5;
    color = clamp(color, 0.0, 1.0);

    // ── Pass 8: Highlight Rolloff（高光柔和压缩）────────────────────────────
    float rolloff = p.highlightRolloff;
    float threshold = 1.0 - rolloff;
    float3 highMask = max(color - threshold, float3(0.0));
    color = color - highMask * (1.0 - exp(-highMask / (rolloff + 0.001)));
    color = clamp(color, 0.0, 1.0);

    // ── Pass 9: Flash Bloom（闪光感柔光，SQC 核心特征）─────────────────────
    // 模拟闪光灯漫射：高亮区域向外扩散暖白光
    float luma9 = dot(color, float3(0.2126, 0.7152, 0.0722));
    float bloomMask = smoothstep(0.55, 0.85, luma9);
    // 暖白柔光（R 略多，G 中等，B 略少）
    float3 bloomColor = float3(1.0, 0.97, 0.92) * bloomMask * p.bloomAmount;
    color = color + bloomColor * (1.0 - color);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 10: Halation（高光发光，闪光感）────────────────────────────────
    float luma10 = dot(color, float3(0.2126, 0.7152, 0.0722));
    float halMask = smoothstep(0.7, 1.0, luma10);
    // 暖粉发光（R 强，G 中，B 弱）
    float3 halColor = float3(1.0, 0.88, 0.80) * halMask * p.halationAmount;
    color = color + halColor * (1.0 - color * 0.6);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 11: Center Gain（中心主体增亮）─────────────────────────────────
    float dist = length(offset);
    float centerMask = 1.0 - smoothstep(0.0, 0.45, dist);
    color = color + centerMask * p.centerGain * (1.0 - color * 0.4);
    color = clamp(color, 0.0, 1.0);

// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW:     // ── Pass 12: Fine Grain（轻颗粒，Instax Square 相纸细腻感）──────────────
    float noise12 = sqcRandom(uv, p.time) * 2.0 - 1.0;
// SIMPLIFIED_PREVIEW: // SIMPLIFIED:     float grainScale = p.grainAmount * (0.5 + 0.5 * (1.0 - dot(color, float3(0.2126, 0.7152, 0.0722))));
    color = color + noise12 * grainScale;
    color = clamp(color, 0.0, 1.0);

// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW:     // ── Pass 13: Paper Texture（相纸纤维纹理）───────────────────────────────
    float2 paperUV = uv * float2(120.0, 120.0);
    float paperNoise = sqcRandom(floor(paperUV) / 120.0, 42.0) * 2.0 - 1.0;
// SIMPLIFIED:     color = color + paperNoise * p.paperTexture * 0.5;
    color = clamp(color, 0.0, 1.0);

    // ── Pass 14: Skin Tone Protection（肤色保护）────────────────────────────
// SIMPLIFIED:     if (p.skinHueProtect > 0.5) {
        float skinMask = sqcSkinMask(color);
        if (skinMask > 0.01) {
            // 肤色饱和度保护：防止过饱和
            float lumaS = dot(color, float3(0.2126, 0.7152, 0.0722));
            float3 desatColor = float3(lumaS);
            float3 protectedColor = mix(desatColor, color, p.skinSatProtect);
            color = mix(color, protectedColor, skinMask);

            // 肤色亮度柔化：轻微提亮暗部肤色
            float lumaSoft = dot(color, float3(0.2126, 0.7152, 0.0722));
            float softLift = p.skinLumaSoften * (1.0 - lumaSoft) * skinMask;
            color = color + softLift;

            // 肤色红限：防止肤色过红
            color.r = min(color.r, color.g * p.skinRedLimit + color.b * 0.1);

            color = clamp(color, 0.0, 1.0);
        }
    }

// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW:     // ── Pass 15: Edge Falloff / Uneven Exposure（不均匀曝光）────────────────
    // 边缘曝光衰减
    float edgeDist = length(offset * float2(1.0, 1.0 / p.aspectRatio));
    float edgeMask = smoothstep(0.0, 0.7, edgeDist);
// SIMPLIFIED:     color = color * (1.0 - edgeMask * p.edgeFalloff);

    // 全局轻微不均匀曝光（模拟化学显影不均匀）
    float expVar = sqcRandom(uv * 0.3, p.time * 0.1) * 2.0 - 1.0;
    color = color * (1.0 + expVar * p.exposureVariation * 0.3);
    color = clamp(color, 0.0, 1.0);

// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW:     // ── Pass 16: Development Softness（显影柔化）────────────────────────────
    // 模拟 Instant 化学显影过程中的轻微扩散柔化
    // 使用局部对比度降低实现柔化效果
    float luma16 = dot(color, float3(0.2126, 0.7152, 0.0722));
// SIMPLIFIED:     float softMask = p.developmentSoftness;
    // 轻微降低局部对比度（高频细节柔化）
    color = mix(color, float3(luma16) * 0.3 + color * 0.7, softMask);
    color = clamp(color, 0.0, 1.0);

// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW:     // ── Pass 17: Chemical Irregularity（化学不规则感）───────────────────────
    // 极轻微的局部色调不规则（模拟化学显影的微小不均匀）
    float2 irregUV = uv * 8.0;
    float irreg = sqcRandom(floor(irregUV) / 8.0, 99.0) * 2.0 - 1.0;
    // 不规则感主要影响色调（轻微色相偏移），不影响亮度
// SIMPLIFIED:     float3 irregShift = float3(irreg * 0.6, irreg * 0.3, irreg * -0.4) * p.chemicalIrregularity;
    color = color + irregShift;
    color = clamp(color, 0.0, 1.0);

// PREVIEW_SIMPLIFIED: // SIMPLIFIED_PREVIEW:     // ── Pass 18: Corner Warm Shift（边角偏暖）───────────────────────────────
    float cornerDist = length(offset);
    float cornerMask = smoothstep(0.3, 0.8, cornerDist);
    // 边角偏暖：加 R 减 B
// SIMPLIFIED:     color.r = clamp(color.r + cornerMask * p.cornerWarmShift * 0.6, 0.0, 1.0);
// SIMPLIFIED:     color.b = clamp(color.b - cornerMask * p.cornerWarmShift * 0.4, 0.0, 1.0);

    // ── Pass 19: Vignette（极轻暗角）────────────────────────────────────────
    float vigDist = length(offset * float2(1.0, 1.0 / p.aspectRatio));
    float vigMask = smoothstep(0.4, 1.0, vigDist);
    color = color * (1.0 - vigMask * p.vignetteAmount * 1.5);
    color = clamp(color, 0.0, 1.0);

    return float4(color, 1.0);
}
