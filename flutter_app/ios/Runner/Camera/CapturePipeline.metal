// CapturePipeline.metal
// DAZZ Camera — iOS Metal Compute Shader 成片处理管线
//
// ═══════════════════════════════════════════════════════════════════════════
// 架构说明：
//   本文件实现 GPU 成片处理管线，在按下快门后对原始 JPEG 执行完整的图像处理。
//   与预览 Shader（InstCShader.metal 等）的区别：
//   - 预览 Shader：Fragment Shader，实时处理每一帧，移除了高开销效果
//   - 成片 Shader：Compute Shader，一次性处理，包含所有效果（含 SIMPLIFIED 效果）
//
// 管线顺序（与 fragment_ccd.glsl 和 Android capture_pipeline.rs 完全一致）：
//   Pass 1:  色差（Chromatic Aberration）
//   Pass 2:  色温 + Tint
//   Pass 3:  黑场/白场
//   Pass 4:  高光/阴影压缩
//   Pass 5:  对比度
//   Pass 6:  Clarity（中间调微对比度）
//   Pass 7:  饱和度 + Vibrance
//   Pass 8:  RGB 通道偏移
//   Pass 9:  Bloom（高光光晕）
//   Pass 10: Highlight Rolloff（高光柔和滴落，成片专属）
//   Pass 11: Center Gain（中心增亮，成片专属）
//   Pass 12: Skin Protection（肤色保护，成片专属）
//   Pass 13: Edge Falloff + Corner Warm Shift（成片专属）
//   Pass 14: Chemical Irregularity（化学不规则感，成片专属）
//   Pass 15: Paper Texture（相纸纹理，成片专属）
//   Pass 16: Film Grain（胶片颗粒）
//   Pass 17: Vignette（暗角）
// ═══════════════════════════════════════════════════════════════════════════

#include <metal_stdlib>
using namespace metal;

// ── 参数结构体（必须与 CaptureProcessor.swift 中的 MetalCaptureParams 完全一致）──

struct CaptureParams {
    int   cameraId;
    float time;
    float aspectRatio;

    // 基础色彩参数
    float contrast;
    float saturation;
    float temperatureShift;
    float tintShift;

    // Lightroom 风格曲线参数
    float highlights;
    float shadows;
    float whites;
    float blacks;
    float clarity;
    float vibrance;

    // RGB 通道偏移
    float colorBiasR;
    float colorBiasG;
    float colorBiasB;

    // 胶片效果参数
    float grainAmount;
    float noiseAmount;
    float vignetteAmount;
    float chromaticAberration;
    float bloomAmount;
    float halationAmount;
    float sharpen;
    float blurRadius;
    float jpegArtifacts;
    float fisheyeMode;
    float grainSize;
    float sharpness;
    float highlightWarmAmount;
    float luminanceNoise;
    float chromaNoise;

    // 成片专属参数
    float highlightRolloff;
    float highlightRolloff2;   // 高光柔和滚落 2（FXN-R 专属）
    float toneCurveStrength;   // Tone Curve 强度（FXN-R 专属）
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
    float exposureOffset;    // 用户曝光补偿（-2.0~+2.0）
    // LUT 参数（成片 GPU 管线）
    float lutEnabled;        // 1.0 = 启用 LUT
    float lutStrength;       // LUT 混合强度（0.0~1.0）
    float lutSize;           // LUT 边长（通常 33）
    float lensDistortion;    // 轻量桶形畸变（非圆形鱼眼）
    // ── Device Calibration（V3：设备级线性校准）──
    float deviceGamma;
    float deviceWhiteScaleR;
    float deviceWhiteScaleG;
    float deviceWhiteScaleB;
    float deviceCcm00;
    float deviceCcm01;
    float deviceCcm02;
    float deviceCcm10;
    float deviceCcm11;
    float deviceCcm12;
    float deviceCcm20;
    float deviceCcm21;
    float deviceCcm22;
    float circularFisheye;
};

// ── 工具函数 ─────────────────────────────────────────────────────────────

/// 圆形鱼眼 UV 重映射（等距投影，与 CameraShaders.metal 完全一致）
/// 返回 float2(-1) 表示圆形以外区域
static float2 cp_fisheyeUV(float2 uv, float aspect) {
    float2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r = length(p);
    // 与预览保持一致：缩小有效圆半径，增强圆形边界可见度。
    constexpr float rMax = 0.98;
    if (r > rMax) return float2(-1.0);
    float rn = r / rMax;
    float theta = rn * 1.5707963; // π/2
    float phi = atan2(p.y, p.x);
    float sinTheta = sin(theta);
    float2 texCoord = float2(sinTheta * cos(phi), sinTheta * sin(phi));
    return texCoord * 0.5 + 0.5;
}

static float2 cp_fisheyeRectUV(float2 uv, float aspect) {
    float2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r = length(p);
    float rCorner = length(float2(aspect, 1.0));
    float rn = clamp(r / max(rCorner, 0.0001), 0.0, 1.0);
    float theta = rn * 1.5707963;
    float phi = atan2(p.y, p.x);
    float sinTheta = sin(theta);
    float2 mapped = float2(sinTheta * cos(phi), sinTheta * sin(phi));
    mapped.x /= max(aspect, 0.0001);
    return clamp(mapped * 0.5 + 0.5, float2(0.0), float2(1.0));
}

static float2 cp_barrelDistortUV(float2 uv, float strength, float aspect) {
    float2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r2 = dot(p, p);
    float k = 1.0 + strength * 0.35 * r2;
    p *= k;
    p.x /= max(aspect, 0.0001);
    return p * 0.5 + 0.5;
}

/// 伪随机数生成（与所有预览 Shader 完全一致）
static float cp_random(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// 色温偏移：正值偏暖（加R减B），负值偏冷（减R加B）
/// 与预览 Shader (CameraShaders.metal applyTemperatureShift) 方向一致
static float3 cp_temperatureShift(float3 color, float shift) {
    float s = shift / 1000.0;
    color.r = clamp(color.r + s * 0.3, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.3, 0.0, 1.0);
    return color;
}

/// Tint 偏色：负值偏绿，正值偏洋红
static float3 cp_tint(float3 color, float tint) {
    float t = tint / 100.0;
    color.g = clamp(color.g - t * 0.12, 0.0, 1.0);
    color.r = clamp(color.r + t * 0.06, 0.0, 1.0);
    color.b = clamp(color.b + t * 0.06, 0.0, 1.0);
    return color;
}

/// 对比度调整（围绕 0.5 缩放）
static float3 cp_contrast(float3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度调整（BT.709 亮度权重）
static float3 cp_saturation(float3 color, float saturation) {
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(lum), color, saturation), 0.0, 1.0);
}

/// 黑场/白场偏移
static float3 cp_blacksWhites(float3 color, float blacks, float whites) {
    float blacksOffset = blacks / 100.0 * (20.0 / 255.0);
    float whitesScale  = 1.0 + whites / 100.0 * 0.15;
    return clamp(color * whitesScale + blacksOffset, 0.0, 1.0);
}

/// 高光/阴影压缩
static float3 cp_highlightsShadows(float3 color, float highlights, float shadows) {
    float hScale  = 1.0 + highlights / 100.0 * 0.12;
    float hOffset = -highlights / 100.0 * 0.12 * (191.0 / 255.0);
    float sScale  = 1.0 - shadows / 100.0 * 0.08;
    float sOffset = shadows / 100.0 * 0.08 * (64.0 / 255.0) + shadows / 100.0 * (12.0 / 255.0);
    return clamp(color * (hScale * sScale) + (hOffset * sScale + sOffset), 0.0, 1.0);
}

/// Clarity：中间调微对比度
static float3 cp_clarity(float3 color, float clarity) {
    float c = clarity / 100.0;
    return clamp(color * (1.0 + c * 0.15) + (-c * 0.15 * 0.5), 0.0, 1.0);
}

/// Vibrance：智能饱和度
static float3 cp_vibrance(float3 color, float vibrance) {
    float v   = vibrance / 100.0 * 0.6;
    float sat = 1.0 + v;
    float sr = (1.0 - sat) * 0.2126;
    float sg = (1.0 - sat) * 0.7152;
    float sb = (1.0 - sat) * 0.0722;
    return clamp(float3(
        color.r * (sr + sat) + color.g * sg + color.b * sb,
        color.r * sr + color.g * (sg + sat) + color.b * sb,
        color.r * sr + color.g * sg + color.b * (sb + sat)
    ), 0.0, 1.0);
}

/// RGB 通道偏移
static float3 cp_colorBias(float3 color, float r, float g, float b) {
    return clamp(color + float3(r * (30.0/255.0), g * (30.0/255.0), b * (30.0/255.0)), 0.0, 1.0);
}
/// Device Calibration（设备级色彩校准：白点缩放 + CCM + Gamma）
static float3 cp_deviceCalibration(float3 color, constant CaptureParams& params) {
    color = clamp(color * float3(params.deviceWhiteScaleR, params.deviceWhiteScaleG, params.deviceWhiteScaleB), 0.0, 1.0);
    float3 row0 = float3(params.deviceCcm00, params.deviceCcm01, params.deviceCcm02);
    float3 row1 = float3(params.deviceCcm10, params.deviceCcm11, params.deviceCcm12);
    float3 row2 = float3(params.deviceCcm20, params.deviceCcm21, params.deviceCcm22);
    color = clamp(float3(
        dot(row0, color),
        dot(row1, color),
        dot(row2, color)
    ), 0.0, 1.0);
    if (fabs(params.deviceGamma - 1.0) > 0.0001) {
        float invGamma = 1.0 / max(params.deviceGamma, 0.001);
        color = pow(clamp(color, 0.0, 1.0), float3(invGamma));
    }
    return clamp(color, 0.0, 1.0);
}

/// Bloom（高光光晕）
static float3 cp_bloom(float3 color, float bloomAmount) {
    if (bloomAmount < 0.001) return color;
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (lum > 0.82) {
        float bloom = clamp((lum - 0.82) * bloomAmount * 1.35, 0.0, 0.12);
        color = clamp(color + float3(bloom * 0.55, bloom * 0.48, bloom * 0.38), 0.0, 1.0);
    }
    return color;
}

/// Highlight Rolloff（高光柔和滴落，成片专属）
static float3 cp_highlightRolloff(float3 color, float rolloff) {
    if (rolloff < 0.001) return color;
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (lum > 0.76) {
        float mask = smoothstep(0.76, 1.0, lum);
        float3 compressed = float3(
            color.r * (1.0 - mask * rolloff * 0.10),
            color.g * (1.0 - mask * rolloff * 0.13),
            color.b * (1.0 - mask * rolloff * 0.18)
        );
        color = clamp(mix(color, compressed, mask * rolloff * 0.75), 0.0, 1.0);
    }
    return color;
}

/// Center Gain（中心增亮，成片专属）
static float3 cp_centerGain(float3 color, float2 uv, float amount) {
    if (amount < 0.001) return color;
    float2 center = uv - 0.5;
    float dist = length(center * float2(1.0, 1.1));
    float centerMask = 1.0 - smoothstep(0.0, 0.45, dist);
    centerMask = centerMask * centerMask;
    return clamp(float3(
        color.r * (1.0 + centerMask * amount * 1.2),
        color.g * (1.0 + centerMask * amount * 1.0),
        color.b * (1.0 + centerMask * amount * 0.7)
    ), 0.0, 1.0);
}

/// Edge Falloff（边缘曝光衰减，成片专属）
static float cp_edgeFalloff(float2 uv, float amount, float time) {
    if (amount < 0.001) return 1.0;
    float2 center = uv - 0.5;
    float edgeDist = dot(center * float2(1.2, 1.0), center * float2(1.2, 1.0));
    float falloff = 1.0 - smoothstep(0.10, 0.35, edgeDist);
    float variation = cp_random(uv * 0.3, floor(time * 0.1) * 0.1) * 2.0 - 1.0;
    falloff = clamp(falloff + variation * 0.3 * amount * 0.5, 0.6, 1.0);
    return mix(1.0, falloff, amount * 1.5);
}

/// Corner Warm Shift（边角偏暖，成片专属）
static float3 cp_cornerWarm(float3 color, float2 uv, float amount) {
    if (amount < 0.001) return color;
    float dist = length(uv - 0.5);
    float cornerMask = smoothstep(0.25, 0.55, dist);
    color.r = clamp(color.r + cornerMask * amount * 0.08, 0.0, 1.0);
    color.b = clamp(color.b - cornerMask * amount * 0.06, 0.0, 1.0);
    return color;
}

/// Paper Texture（相纸纹理，成片专属）
static float3 cp_paperTexture(float3 color, float2 uv, float amount, float time) {
    if (amount < 0.001) return color;
    float paper1 = cp_random(uv * 8.0, 0.0) * 2.0 - 1.0;
    float paper2 = cp_random(uv * 32.0, 1.0) * 2.0 - 1.0;
    float paper = paper1 * 0.7 + paper2 * 0.3;
    return clamp(color + float3(paper * amount * 0.04), 0.0, 1.0);
}

/// Chemical Irregularity（化学不规则感，成片专属）
static float3 cp_chemicalIrregularity(float3 color, float2 uv, float amount, float time) {
    if (amount < 0.001) return color;
    float2 irregUV = uv * 2.5;
    float irreg1 = cp_random(irregUV, floor(time * 0.1) * 0.1) * 2.0 - 1.0;
    float irreg2 = cp_random(irregUV * 1.7 + 0.3, floor(time * 0.1) * 0.2) * 2.0 - 1.0;
    float irregularity = irreg1 * 0.6 + irreg2 * 0.4;
    float brightVar = irregularity * amount * 0.03;
    return clamp(color + float3(brightVar + irregularity * amount * 0.008,
                                brightVar + irregularity * amount * 0.004,
                                brightVar - irregularity * amount * 0.006), 0.0, 1.0);
}

/// Skin Protection（肤色保护，成片专属）
static float3 cp_skinProtect(float3 color, float skinHueProtect, float skinSatProtect,
                              float skinLumaSoften, float skinRedLimit) {
    if (skinHueProtect < 0.5) return color;

    float maxC = max(max(color.r, color.g), color.b);
    float minC = min(min(color.r, color.g), color.b);
    float delta = maxC - minC;
    float lum = (maxC + minC) * 0.5;
    float sat = (delta < 0.001) ? 0.0 : delta / (1.0 - abs(2.0 * lum - 1.0));

    float hue = 0.0;
    if (delta > 0.001) {
        if (maxC == color.r)      hue = fmod((color.g - color.b) / delta, 6.0);
        else if (maxC == color.g) hue = (color.b - color.r) / delta + 2.0;
        else                      hue = (color.r - color.g) / delta + 4.0;
        hue = hue / 6.0;
        if (hue < 0.0) hue += 1.0;
    }

    bool isSkin = (hue >= 0.0 && hue <= 0.139) &&
                  (sat >= 0.15 && sat <= 0.85) &&
                  (lum >= 0.20 && lum <= 0.85);
    if (!isSkin) return color;

    float hueMask  = 1.0 - smoothstep(0.10, 0.139, hue);
    float satMask  = smoothstep(0.15, 0.25, sat) * (1.0 - smoothstep(0.75, 0.85, sat));
    float lumMask  = smoothstep(0.20, 0.35, lum) * (1.0 - smoothstep(0.75, 0.85, lum));
    float skinMask = hueMask * satMask * lumMask;

    float lumVal = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 desat = mix(float3(lumVal), color, skinSatProtect);
    float3 result = mix(color, desat, skinMask * 0.6);
    result = clamp(result + float3(lum * skinLumaSoften * 0.8), 0.0, 1.0);
    result.r = clamp(result.r, 0.0, skinRedLimit);
    return clamp(mix(color, result, skinMask), 0.0, 1.0);
}

/// Highlight Rolloff 2（FXN-R 专属，二次压缩）
static float3 cp_highlightRolloff2(float3 color, float rolloff) {
    if (rolloff < 0.001) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.3;
    return clamp(color * compress, 0.0, 1.0);
}

/// Tone Curve（FXN-R 专属，分段线性插値）
static float cp_toneCurve(float x) {
    const float inp[10]  = {0.0, 0.0627, 0.1255, 0.2510, 0.3765, 0.5020, 0.6275, 0.7529, 0.8784, 1.0};
    const float outV[10] = {0.0, 0.0392, 0.0941, 0.2235, 0.3608, 0.4863, 0.6588, 0.8235, 0.9333, 0.9804};
    for (int i = 0; i < 9; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outV[i], outV[i + 1], t);
        }
    }
    return outV[9];
}

/// Development Softness（显影柔化）
static float3 cp_developmentSoften(float3 color, float2 uv, float softness,
                                    texture2d<float, access::read> inTex, uint2 gid) {
    if (softness < 0.001) return color;
    uint w = inTex.get_width();
    uint h = inTex.get_height();
    float3 blurred =
        inTex.read(uint2(clamp(int(gid.x) - 1, 0, int(w)-1), gid.y)).rgb * 0.25 +
        inTex.read(uint2(clamp(int(gid.x) + 1, 0, int(w)-1), gid.y)).rgb * 0.25 +
        inTex.read(uint2(gid.x, clamp(int(gid.y) - 1, 0, int(h)-1))).rgb * 0.25 +
        inTex.read(uint2(gid.x, clamp(int(gid.y) + 1, 0, int(h)-1))).rgb * 0.25;
    return mix(color, blurred, softness * 0.5);
}

/// Film Grain（成片专用：hash 低频颗粒，更接近真实胶片质感）
static float3 cp_grain(float3 color, float2 uv, float amount, float grainSize, float time) {
    if (amount < 0.001) return color;
    float grain  = cp_random(uv * 500.0, time * 0.1) - 0.5;
    float grain2 = cp_random(uv * 250.0, time * 0.07 + time * 0.13) - 0.5;
    float g = mix(grain, grain2, 0.3);
    return clamp(color + float3(g * amount * 0.25), 0.0, 1.0);
}

/// Vignette（smoothstep 暗角，与预览统一）
static float cp_vignette(float2 uv, float amount) {
    float2 d = uv - 0.5;
    float dist = length(d) * 2.0;
    return 1.0 - smoothstep(1.0 - amount, 1.5, dist) * amount;
}
// ── LUT 采样函数（与 CameraShaders.metal sampleLUT 完全一致）────────────────────────────────────────────────────────────────────
/// 3D LUT 采样（将 3D LUT 布局在 2D 纹理中：宽 = N*N，高 = N）
static float3 cp_sampleLUT(texture2d<float> lut, sampler s, float3 color, float lutN) {
    float scale  = (lutN - 1.0) / lutN;
    float offset = 0.5 / lutN;
    float3 lutCoord = color * scale + offset;
    float bSlice = lutCoord.b * (lutN - 1.0);
    float bLow   = floor(bSlice);
    float bHigh  = min(bLow + 1.0, lutN - 1.0);
    float bFrac  = bSlice - bLow;
    float texW   = lutN * lutN;
    float texH   = lutN;
    float2 uvLow  = float2((bLow  * lutN + lutCoord.r * (lutN - 1.0) + 0.5) / texW,
                           (lutCoord.g * (lutN - 1.0) + 0.5) / texH);
    float2 uvHigh = float2((bHigh * lutN + lutCoord.r * (lutN - 1.0) + 0.5) / texW,
                           (lutCoord.g * (lutN - 1.0) + 0.5) / texH);
    float3 colLow  = lut.sample(s, uvLow).rgb;
    float3 colHigh = lut.sample(s, uvHigh).rgb;
    return mix(colLow, colHigh, bFrac);
}

// ── 主内核函数 ────────────────────────────────────────────────────────────────────
kernel void capturePipeline(
    texture2d<float, access::read>   inTexture  [[texture(0)]],
    texture2d<float, access::write>  outTexture [[texture(1)]],
    constant CaptureParams&          params     [[buffer(0)]],
    texture2d<float>                 lutTexture [[texture(2)]],
    uint2                            gid        [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = float2(gid) / float2(outTexture.get_width(), outTexture.get_height());

    // ── Pass 0: 鱼眼模式 — UV 重映射 + 圆形遮罩（与预览 Shader 完全一致）─────────
    bool isFisheye = params.fisheyeMode > 0.5;
    bool useCircularFisheye = params.circularFisheye > 0.5;
    if (isFisheye) {
        if (useCircularFisheye) {
            float2 fUV = cp_fisheyeUV(uv, params.aspectRatio);
            if (fUV.x < 0.0) {
                outTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
                return;
            }
            uv = fUV;
        } else {
            uv = cp_fisheyeRectUV(uv, params.aspectRatio);
        }
    } else if (fabs(params.lensDistortion) > 0.0001) {
        uv = clamp(cp_barrelDistortUV(uv, params.lensDistortion, params.aspectRatio), float2(0.0), float2(1.0));
    }

    float3 color = inTexture.read(uint2(uv * float2(inTexture.get_width(), inTexture.get_height()))).rgb;

    // ── Pass 1: 色差（Chromatic Aberration）────────────────────────────────
    // Compute Shader 不支持任意纹理采样，色差效果在 CaptureProcessor.swift 中预处理
    // 这里直接使用已处理的像素

        // ── Pass 1.5: 曝光补偿（在色温之前应用，模拟相机 EV 补偿）────────────────
    if (params.exposureOffset != 0.0) {
        color *= pow(2.0, params.exposureOffset);
        color = clamp(color, 0.0, 1.0);
    }

    // ── Pass 1.75: 设备级色彩校准（白点缩放 + CCM + Gamma）──────────────────────────
    color = cp_deviceCalibration(color, params);

    // ── Pass 2: 色温 + Tint ────────────────────────────────────────
    color = cp_temperatureShift(color, params.temperatureShift);
    color = cp_tint(color, params.tintShift);

    // ── Pass 3: 黑场/白场 ─────────────────────────────────────────────────
    color = cp_blacksWhites(color, params.blacks, params.whites);

    // ── Pass 4: 高光/阴影压缩 ─────────────────────────────────────────────
    color = cp_highlightsShadows(color, params.highlights, params.shadows);

    // ── Pass 5: 对比度 ────────────────────────────────────────────────────
    color = cp_contrast(color, params.contrast);

    // ── Pass 6: Clarity ───────────────────────────────────────────────────
    if (abs(params.clarity) > 0.5) {
        color = cp_clarity(color, params.clarity);
    }

    // ── Pass 7: 饱和度 + Vibrance ─────────────────────────────────────────
    color = cp_saturation(color, params.saturation);
    if (abs(params.vibrance) > 0.5) {
        color = cp_vibrance(color, params.vibrance);
    }

    // ── Pass 8: RGB 通道偏移 ──────────────────────────────────────────────
    if (abs(params.colorBiasR) + abs(params.colorBiasG) + abs(params.colorBiasB) > 0.001) {
        color = cp_colorBias(color, params.colorBiasR, params.colorBiasG, params.colorBiasB);
    }

    // ── Pass 9: Bloom（高光光晕）─────────────────────────────────────────
    color = cp_bloom(color, params.bloomAmount);

    // ── Pass 10: Highlight Rolloff（成片专属）────────────────────────────────────────
    color = cp_highlightRolloff(color, params.highlightRolloff);

    // ── Pass 10b: Highlight Rolloff 2（FXN-R 专属）────────────────────────────────
    if (params.highlightRolloff2 > 0.001) {
        color = cp_highlightRolloff2(color, params.highlightRolloff2);
    }

    // ── Pass 10c: Tone Curve（FXN-R 专属）──────────────────────────────────────────
    if (params.toneCurveStrength > 0.001) {
        float3 curved = float3(cp_toneCurve(color.r), cp_toneCurve(color.g), cp_toneCurve(color.b));
        color = mix(color, curved, params.toneCurveStrength);
    }

    // ── Pass 11: Center Gain（成片专属）──────────────────────────────────────────
    color = cp_centerGain(color, uv, params.centerGain);

    // ── Pass 12: Skin Protection（成片专属）──────────────────────────────────────
    color = cp_skinProtect(color, params.skinHueProtect, params.skinSatProtect,
                           params.skinLumaSoften, params.skinRedLimit);

    // ── Pass 13: Edge Falloff + Corner Warm Shift（成片专属）───────────────────────
    color *= cp_edgeFalloff(uv, params.edgeFalloff, params.time);
    color = cp_cornerWarm(color, uv, params.cornerWarmShift);

    // ── Pass 13b: Development Softness（显影柔化）────────────────────────────────────
    if (params.developmentSoftness > 0.001) {
        color = cp_developmentSoften(color, uv, params.developmentSoftness, inTexture, gid);
    }

    // ── Pass 14: Chemical Irregularity（成片专属）──────────────────────────────────
    color = cp_chemicalIrregularity(color, uv, params.chemicalIrregularity, params.time);

    // ── Pass 15: Paper Texture（成片专属）──────────────────────────────────────────
    color = cp_paperTexture(color, uv, params.paperTexture, params.time);

    // ── Pass 16: Film Grain（胶片颗粒）─────────────────────────────────────────────
    color = cp_grain(color, uv, params.grainAmount, params.grainSize, params.time);

    // ── Pass 17: Vignette（暗角）──────────────────────────────────────────────────
    // 鱼眼模式下不叠加额外暗角，圆形边缘已有自然渐暗（与预览 Shader 一致）
    if (params.vignetteAmount > 0.001 && (!isFisheye || !useCircularFisheye)) {
        color *= cp_vignette(uv, params.vignetteAmount);
    }

    // ── Pass 18: LUT 色彩映射（成片专属）───────────────────────────────────────────────
    if (params.lutEnabled > 0.5) {
        float3 lutColor = cp_sampleLUT(lutTexture, s, color, params.lutSize);
        color = mix(color, lutColor, params.lutStrength);
    }
    // ── 写入输出纹理 ────────────────────────────────────────────────────────────────────
    outTexture.write(float4(color, 1.0), gid);
}
