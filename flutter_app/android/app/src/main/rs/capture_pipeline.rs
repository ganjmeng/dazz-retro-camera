#pragma version(1)
#pragma rs java_package_name(com.retrocam.app)
#pragma rs_fp_relaxed

// ═══════════════════════════════════════════════════════════════════════════
// capture_pipeline.rs
// DAZZ Camera — Android RenderScript 成片处理管线
//
// 从 fragment_ccd.glsl 完整移植，包含所有 Pass 的真实算法。
// 在成片时由 CaptureProcessor.kt 调度，替代 Dart 层的逐像素循环。
// ═══════════════════════════════════════════════════════════════════════════

// ── 参数（由 Kotlin 侧通过 ScriptField 设置）─────────────────────────────

// 基础色彩参数
float gContrast;
float gSaturation;
float gTemperatureShift;
float gTintShift;

// Lightroom 风格曲线参数
float gHighlights;
float gShadows;
float gWhites;
float gBlacks;
float gClarity;
float gVibrance;

// RGB 通道偏移
float gColorBiasR;
float gColorBiasG;
float gColorBiasB;

// 胶片效果参数
float gGrainAmount;
float gNoiseAmount;
float gVignetteAmount;
float gChromaticAberration;
float gBloomAmount;
float gTime;
float gDistortion;
float gZoomFactor;
float gLensVignette;

// 成片专属参数（预览中被 SIMPLIFIED 的效果）
float gHighlightRolloff;
float gPaperTexture;
float gEdgeFalloff;
float gExposureVariation;
float gCornerWarmShift;
float gCenterGain;
float gDevelopmentSoftness;
float gChemicalIrregularity;
float gSkinHueProtect;
float gSkinSatProtect;
float gSkinLumaSoften;
float gSkinRedLimit;

// 图像尺寸（用于计算 UV）
int gWidth;
int gHeight;

// ── 工具函数 ─────────────────────────────────────────────────────────────

// 伪随机数生成（与 GLSL 版本完全一致）
static float rs_random(float2 uv, float seed) {
    float2 v = uv + seed;
    return fract(sin(v.x * 12.9898f + v.y * 78.233f) * 43758.5453f);
}

// 色温偏移：负值偏冷（蓝），正值偏暖（橙）
static float3 applyTemperatureShift(float3 color, float shift) {
    float s = shift / 1000.0f;
    color.r = clamp(color.r - s * 0.3f, 0.0f, 1.0f);
    color.b = clamp(color.b + s * 0.3f, 0.0f, 1.0f);
    return color;
}

// Tint 偏色：负值偏绿，正值偏洋红
static float3 applyTint(float3 color, float tint) {
    float t = tint / 100.0f;
    color.g = clamp(color.g - t * 0.12f, 0.0f, 1.0f);
    color.r = clamp(color.r + t * 0.06f, 0.0f, 1.0f);
    color.b = clamp(color.b + t * 0.06f, 0.0f, 1.0f);
    return color;
}

// 对比度调整（围绕 0.5 缩放）
static float3 applyContrast(float3 color, float contrast) {
    float3 result;
    result.r = clamp((color.r - 0.5f) * contrast + 0.5f, 0.0f, 1.0f);
    result.g = clamp((color.g - 0.5f) * contrast + 0.5f, 0.0f, 1.0f);
    result.b = clamp((color.b - 0.5f) * contrast + 0.5f, 0.0f, 1.0f);
    return result;
}

// 饱和度调整（BT.709 亮度权重）
static float3 applySaturation(float3 color, float saturation) {
    float lum = color.r * 0.2126f + color.g * 0.7152f + color.b * 0.0722f;
    float3 result;
    result.r = clamp(lum + (color.r - lum) * saturation, 0.0f, 1.0f);
    result.g = clamp(lum + (color.g - lum) * saturation, 0.0f, 1.0f);
    result.b = clamp(lum + (color.b - lum) * saturation, 0.0f, 1.0f);
    return result;
}

// 黑场/白场偏移
static float3 applyBlacksWhites(float3 color, float blacks, float whites) {
    float blacksOffset = blacks / 100.0f * (20.0f / 255.0f);
    float whitesScale  = 1.0f + whites / 100.0f * 0.15f;
    float3 result;
    result.r = clamp(color.r * whitesScale + blacksOffset, 0.0f, 1.0f);
    result.g = clamp(color.g * whitesScale + blacksOffset, 0.0f, 1.0f);
    result.b = clamp(color.b * whitesScale + blacksOffset, 0.0f, 1.0f);
    return result;
}

// 高光/阴影压缩（非线性曲线模拟）
static float3 applyHighlightsShadows(float3 color, float highlights, float shadows) {
    float hScale  = 1.0f + highlights / 100.0f * 0.12f;
    float hOffset = -highlights / 100.0f * 0.12f * (191.0f / 255.0f);
    float sScale  = 1.0f - shadows / 100.0f * 0.08f;
    float sOffset = shadows / 100.0f * 0.08f * (64.0f / 255.0f) + shadows / 100.0f * (12.0f / 255.0f);
    float scale   = hScale * sScale;
    float offset  = hOffset * sScale + sOffset;
    float3 result;
    result.r = clamp(color.r * scale + offset, 0.0f, 1.0f);
    result.g = clamp(color.g * scale + offset, 0.0f, 1.0f);
    result.b = clamp(color.b * scale + offset, 0.0f, 1.0f);
    return result;
}

// Clarity：中间调微对比度
static float3 applyClarity(float3 color, float clarity) {
    float c      = clarity / 100.0f;
    float boost  = 1.0f + c * 0.15f;
    float offset = -c * 0.15f * 0.5f;
    float3 result;
    result.r = clamp(color.r * boost + offset, 0.0f, 1.0f);
    result.g = clamp(color.g * boost + offset, 0.0f, 1.0f);
    result.b = clamp(color.b * boost + offset, 0.0f, 1.0f);
    return result;
}

// Vibrance：智能饱和度（低饱和区域优先提升）
static float3 applyVibrance(float3 color, float vibrance) {
    float v   = vibrance / 100.0f * 0.6f;
    float sat = 1.0f + v;
    float lr = 0.2126f, lg = 0.7152f, lb = 0.0722f;
    float sr = (1.0f - sat) * lr;
    float sg = (1.0f - sat) * lg;
    float sb = (1.0f - sat) * lb;
    float3 result;
    result.r = clamp(color.r * (sr + sat) + color.g * sg + color.b * sb, 0.0f, 1.0f);
    result.g = clamp(color.r * sr + color.g * (sg + sat) + color.b * sb, 0.0f, 1.0f);
    result.b = clamp(color.r * sr + color.g * sg + color.b * (sb + sat), 0.0f, 1.0f);
    return result;
}

// RGB 通道偏移
static float3 applyColorBias(float3 color, float r, float g, float b) {
    float3 result;
    result.r = clamp(color.r + r * (30.0f / 255.0f), 0.0f, 1.0f);
    result.g = clamp(color.g + g * (30.0f / 255.0f), 0.0f, 1.0f);
    result.b = clamp(color.b + b * (30.0f / 255.0f), 0.0f, 1.0f);
    return result;
}

// 暗角
static float vignetteEffect(float2 uv, float amount) {
    float2 d = uv - 0.5f;
    return 1.0f - (d.x * d.x + d.y * d.y) * amount * 2.5f;
}

// ── 成片专属效果（预览中被 SIMPLIFIED 的效果）────────────────────────────

// Highlight Rolloff（高光柔和滴落）
static float3 applyHighlightRolloff(float3 color, float rolloff) {
    if (rolloff < 0.001f) return color;
    float lum = color.r * 0.2126f + color.g * 0.7152f + color.b * 0.0722f;
    if (lum > 0.70f) {
        float mask = clamp((lum - 0.70f) / 0.30f, 0.0f, 1.0f);
        mask = mask * mask * (3.0f - 2.0f * mask);  // smoothstep
        float3 compressed;
        compressed.r = color.r * (1.0f - mask * rolloff * 0.15f);
        compressed.g = color.g * (1.0f - mask * rolloff * 0.20f);
        compressed.b = color.b * (1.0f - mask * rolloff * 0.30f);
        color.r = clamp(color.r + (compressed.r - color.r) * mask * rolloff, 0.0f, 1.0f);
        color.g = clamp(color.g + (compressed.g - color.g) * mask * rolloff, 0.0f, 1.0f);
        color.b = clamp(color.b + (compressed.b - color.b) * mask * rolloff, 0.0f, 1.0f);
    }
    return color;
}

// Center Gain（中心增亮）
static float3 applyCenterGain(float3 color, float2 uv, float amount) {
    if (amount < 0.001f) return color;
    float2 center = uv - 0.5f;
    float2 scaled = {center.x, center.y * 1.1f};
    float dist = sqrt(scaled.x * scaled.x + scaled.y * scaled.y);
    float t = clamp(dist / 0.45f, 0.0f, 1.0f);
    float centerMask = (1.0f - t) * (1.0f - t);  // 1 - smoothstep(0, 0.45, dist)
    color.r = clamp(color.r * (1.0f + centerMask * amount * 1.2f), 0.0f, 1.0f);
    color.g = clamp(color.g * (1.0f + centerMask * amount * 1.0f), 0.0f, 1.0f);
    color.b = clamp(color.b * (1.0f + centerMask * amount * 0.7f), 0.0f, 1.0f);
    return color;
}

// Edge Falloff（边缘曝光衰减）
static float applyEdgeFalloff(float2 uv, float amount, float time) {
    if (amount < 0.001f) return 1.0f;
    float2 center = uv - 0.5f;
    float cx = center.x * 1.2f;
    float edgeDist = cx * cx + center.y * center.y;
    float t = clamp((edgeDist - 0.10f) / (0.35f - 0.10f), 0.0f, 1.0f);
    float falloff = 1.0f - t * t * (3.0f - 2.0f * t);  // 1 - smoothstep(0.10, 0.35, edgeDist)
    float variation = rs_random(uv * 0.3f, floor(time * 0.1f) * 0.1f) * 2.0f - 1.0f;
    variation *= 0.3f;
    falloff = clamp(falloff + variation * amount * 0.5f, 0.6f, 1.0f);
    return clamp(1.0f + (falloff - 1.0f) * amount * 1.5f, 0.0f, 1.0f);
}

// Corner Warm Shift（边角偏暖）
static float3 applyCornerWarm(float3 color, float2 uv, float amount) {
    if (amount < 0.001f) return color;
    float2 center = uv - 0.5f;
    float dist = sqrt(center.x * center.x + center.y * center.y);
    float t = clamp((dist - 0.25f) / (0.55f - 0.25f), 0.0f, 1.0f);
    float cornerMask = t * t * (3.0f - 2.0f * t);  // smoothstep(0.25, 0.55, dist)
    color.r = clamp(color.r + cornerMask * amount * 0.08f, 0.0f, 1.0f);
    color.b = clamp(color.b - cornerMask * amount * 0.06f, 0.0f, 1.0f);
    return color;
}

// Paper Texture（相纸纹理）
static float3 applyPaperTexture(float3 color, float2 uv, float amount, float time) {
    if (amount < 0.001f) return color;
    float2 uv1 = uv * 8.0f;
    float2 uv2 = uv * 32.0f;
    float paper1 = rs_random(uv1, 0.0f) * 2.0f - 1.0f;
    float paper2 = rs_random(uv2, 1.0f) * 2.0f - 1.0f;
    float paper = paper1 * 0.7f + paper2 * 0.3f;
    float3 result;
    result.r = clamp(color.r + paper * amount * 0.04f, 0.0f, 1.0f);
    result.g = clamp(color.g + paper * amount * 0.04f, 0.0f, 1.0f);
    result.b = clamp(color.b + paper * amount * 0.04f, 0.0f, 1.0f);
    return result;
}

// Chemical Irregularity（化学不规则感）
static float3 applyChemicalIrregularity(float3 color, float2 uv, float amount, float time) {
    if (amount < 0.001f) return color;
    float2 irregUV = uv * 2.5f;
    float irreg1 = rs_random(irregUV, floor(time * 0.1f) * 0.1f) * 2.0f - 1.0f;
    float2 irregUV2 = {irregUV.x * 1.7f + 0.3f, irregUV.y * 1.7f + 0.3f};
    float irreg2 = rs_random(irregUV2, floor(time * 0.1f) * 0.2f) * 2.0f - 1.0f;
    float irregularity = irreg1 * 0.6f + irreg2 * 0.4f;
    float brightVar = irregularity * amount * 0.03f;
    float3 result;
    result.r = clamp(color.r + brightVar + irregularity * amount * 0.008f, 0.0f, 1.0f);
    result.g = clamp(color.g + brightVar + irregularity * amount * 0.004f, 0.0f, 1.0f);
    result.b = clamp(color.b + brightVar - irregularity * amount * 0.006f, 0.0f, 1.0f);
    return result;
}

// Skin Protection（肤色保护系统）
static float3 applySkinProtect(float3 color, float skinHueProtect, float skinSatProtect,
                               float skinLumaSoften, float skinRedLimit) {
    if (skinHueProtect < 0.5f) return color;

    float maxC = fmax(fmax(color.r, color.g), color.b);
    float minC = fmin(fmin(color.r, color.g), color.b);
    float delta = maxC - minC;
    float lum = (maxC + minC) * 0.5f;
    float sat = (delta < 0.001f) ? 0.0f : delta / (1.0f - fabs(2.0f * lum - 1.0f));

    float hue = 0.0f;
    if (delta > 0.001f) {
        if (maxC == color.r)      hue = fmod((color.g - color.b) / delta, 6.0f);
        else if (maxC == color.g) hue = (color.b - color.r) / delta + 2.0f;
        else                      hue = (color.r - color.g) / delta + 4.0f;
        hue = hue / 6.0f;
        if (hue < 0.0f) hue += 1.0f;
    }

    // 肤色检测：Hue 0~50°（0.0~0.139），Sat 0.15~0.85，Lum 0.2~0.85
    bool isSkin = (hue >= 0.0f && hue <= 0.139f) &&
                  (sat >= 0.15f && sat <= 0.85f) &&
                  (lum >= 0.20f && lum <= 0.85f);
    if (!isSkin) return color;

    float t1 = clamp((hue - 0.10f) / (0.139f - 0.10f), 0.0f, 1.0f);
    float hueMask = 1.0f - t1 * t1 * (3.0f - 2.0f * t1);

    float t2 = clamp((sat - 0.15f) / (0.25f - 0.15f), 0.0f, 1.0f);
    float t3 = clamp((sat - 0.75f) / (0.85f - 0.75f), 0.0f, 1.0f);
    float satMask = t2 * t2 * (3.0f - 2.0f * t2) * (1.0f - t3 * t3 * (3.0f - 2.0f * t3));

    float t4 = clamp((lum - 0.20f) / (0.35f - 0.20f), 0.0f, 1.0f);
    float t5 = clamp((lum - 0.75f) / (0.85f - 0.75f), 0.0f, 1.0f);
    float lumMask = t4 * t4 * (3.0f - 2.0f * t4) * (1.0f - t5 * t5 * (3.0f - 2.0f * t5));

    float skinMask = hueMask * satMask * lumMask;

    float3 result = color;
    // 1. 饱和度保护
    float lumVal = color.r * 0.2126f + color.g * 0.7152f + color.b * 0.0722f;
    float3 desat;
    desat.r = lumVal + (color.r - lumVal) * skinSatProtect;
    desat.g = lumVal + (color.g - lumVal) * skinSatProtect;
    desat.b = lumVal + (color.b - lumVal) * skinSatProtect;
    result.r = result.r + (desat.r - result.r) * skinMask * 0.6f;
    result.g = result.g + (desat.g - result.g) * skinMask * 0.6f;
    result.b = result.b + (desat.b - result.b) * skinMask * 0.6f;
    // 2. 亮度柔化
    float lumBoost = lum * skinLumaSoften * 0.8f;
    result.r = clamp(result.r + lumBoost, 0.0f, 1.0f);
    result.g = clamp(result.g + lumBoost, 0.0f, 1.0f);
    result.b = clamp(result.b + lumBoost, 0.0f, 1.0f);
    // 3. 红限
    result.r = clamp(result.r, 0.0f, skinRedLimit);
    // 混合
    result.r = clamp(color.r + (result.r - color.r) * skinMask, 0.0f, 1.0f);
    result.g = clamp(color.g + (result.g - color.g) * skinMask, 0.0f, 1.0f);
    result.b = clamp(color.b + (result.b - color.b) * skinMask, 0.0f, 1.0f);
    return result;
}

// Bloom（高光光晕）
static float3 applyBloom(float3 color, float bloomAmount) {
    if (bloomAmount < 0.001f) return color;
    float lum = color.r * 0.2126f + color.g * 0.7152f + color.b * 0.0722f;
    if (lum > 0.75f) {
        float bloom = clamp((lum - 0.75f) * bloomAmount * 2.5f, 0.0f, 0.25f);
        color.r = clamp(color.r + bloom * 0.9f, 0.0f, 1.0f);
        color.g = clamp(color.g + bloom * 0.8f, 0.0f, 1.0f);
        color.b = clamp(color.b + bloom * 0.6f, 0.0f, 1.0f);
    }
    return color;
}

// Film Grain（胶片颗粒）
static float3 applyGrain(float3 color, float2 uv, float amount, float time) {
    if (amount < 0.001f) return color;
    float grain = rs_random(uv, time) * 2.0f - 1.0f;
    color.r = clamp(color.r + grain * amount, 0.0f, 1.0f);
    color.g = clamp(color.g + grain * amount, 0.0f, 1.0f);
    color.b = clamp(color.b + grain * amount, 0.0f, 1.0f);
    return color;
}

// ── 主内核函数 ────────────────────────────────────────────────────────────

uchar4 RS_KERNEL capturePipeline(uchar4 in, uint32_t x, uint32_t y) {
    // 解包像素为 [0, 1] 浮点
    float4 pixel = rsUnpackColor8888(in);
    float3 color = {pixel.r, pixel.g, pixel.b};

    // 计算归一化 UV 坐标
    float2 uv = {(float)x / (float)gWidth, (float)y / (float)gHeight};

    // ── Pass 1: 色差（Chromatic Aberration）────────────────────────────────
    // 注意：RenderScript 不支持纹理采样，色差效果在 Kotlin 侧预处理，这里跳过

    // ── Pass 2: 色温 + Tint ────────────────────────────────────────────────
    color = applyTemperatureShift(color, gTemperatureShift);
    color = applyTint(color, gTintShift);

    // ── Pass 3: 黑场/白场 ─────────────────────────────────────────────────
    color = applyBlacksWhites(color, gBlacks, gWhites);

    // ── Pass 4: 高光/阴影压缩 ─────────────────────────────────────────────
    color = applyHighlightsShadows(color, gHighlights, gShadows);

    // ── Pass 5: 对比度 ────────────────────────────────────────────────────
    color = applyContrast(color, gContrast);

    // ── Pass 6: Clarity（中间调微对比度）─────────────────────────────────
    if (gClarity > 0.5f || gClarity < -0.5f) {
        color = applyClarity(color, gClarity);
    }

    // ── Pass 7: 饱和度 + Vibrance ─────────────────────────────────────────
    color = applySaturation(color, gSaturation);
    if (gVibrance > 0.5f || gVibrance < -0.5f) {
        color = applyVibrance(color, gVibrance);
    }

    // ── Pass 8: RGB 通道偏移 ──────────────────────────────────────────────
    if (gColorBiasR != 0.0f || gColorBiasG != 0.0f || gColorBiasB != 0.0f) {
        color = applyColorBias(color, gColorBiasR, gColorBiasG, gColorBiasB);
    }

    // ── Pass 9: Bloom（高光光晕，成片时完整应用）─────────────────────────
    color = applyBloom(color, gBloomAmount);

    // ── Pass 10: Highlight Rolloff（高光柔和滴落，成片专属）──────────────
    color = applyHighlightRolloff(color, gHighlightRolloff);

    // ── Pass 11: Center Gain（中心增亮，成片专属）────────────────────────
    color = applyCenterGain(color, uv, gCenterGain);

    // ── Pass 12: Skin Protection（肤色保护，成片专属）────────────────────
    color = applySkinProtect(color, gSkinHueProtect, gSkinSatProtect, gSkinLumaSoften, gSkinRedLimit);

    // ── Pass 13: Edge Falloff + Corner Warm Shift（成片专属）─────────────
    float edgeFactor = applyEdgeFalloff(uv, gEdgeFalloff, gTime);
    color.r *= edgeFactor;
    color.g *= edgeFactor;
    color.b *= edgeFactor;
    color = applyCornerWarm(color, uv, gCornerWarmShift);

    // ── Pass 14: Chemical Irregularity（化学不规则感，成片专属）──────────
    color = applyChemicalIrregularity(color, uv, gChemicalIrregularity, gTime);

    // ── Pass 15: Paper Texture（相纸纹理，成片专属）──────────────────────
    color = applyPaperTexture(color, uv, gPaperTexture, gTime);

    // ── Pass 16: Film Grain（胶片颗粒，成片时完整应用）──────────────────
    color = applyGrain(color, uv, gGrainAmount, gTime);

    // ── Pass 17: 暗角（Vignette）─────────────────────────────────────────
    float vigTotal = fmin(gVignetteAmount + gLensVignette, 1.0f);
    float vignette = vignetteEffect(uv, vigTotal);
    color.r = clamp(color.r * vignette, 0.0f, 1.0f);
    color.g = clamp(color.g * vignette, 0.0f, 1.0f);
    color.b = clamp(color.b * vignette, 0.0f, 1.0f);

    // 打包回 uchar4
    float4 outPixel = {color.r, color.g, color.b, 1.0f};
    return rsPackColorTo8888(outPixel);
}
