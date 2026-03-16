package com.retrocam.app.camera

/**
 * SQCGLRenderer — SQC (Instax Square 升级版) Android GLSL ES 3.0 Shader
 *
 * 风格定位：Fujifilm Instax Square 升级版 preset
 *   - 高于 Inst C 的饱和度（1.18）、亮度（+0.06）
 *   - 更明显暖粉感（temperature=+15，tint=+18）
 *   - 更强闪光感（bloom=0.14，halation=0.06）
 *   - 中心主体感（centerGain=0.03）
 *   - 肤色保护（skinHueProtect=true）
 *   - 显影柔化 + 化学不规则感
 *
 * GPU Pipeline 顺序（19 Pass）：
 *   Chromatic Aberration → White Balance → Tone Curve → RGB Channel Shift
 *   → Brightness Lift → Saturation → Contrast → Highlight Rolloff
 *   → Flash Bloom → Halation → Center Gain → Fine Grain → Paper Texture
 *   → Skin Tone Protection → Edge Falloff / Uneven Exposure
 *   → Development Softness → Chemical Irregularity → Corner Warm Shift
 *   → Vignette → Output
 */
object SQCGLRenderer {

    // ─────────────────────────────────────────────────────────────────────────
    // GLSL ES 3.0 Fragment Shader
    // ─────────────────────────────────────────────────────────────────────────
    const val FRAGMENT_SHADER = """
#version 300 es
precision highp float;

in vec2 vTexCoord;
out vec4 fragColor;

uniform sampler2D uCameraTexture;
uniform vec2 uTexelSize;       // 1.0 / textureSize
uniform float uTime;           // 每帧更新的时间种子

// ── 通用参数 ──────────────────────────────────────────────────────────────
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift;
uniform float uTintShift;
uniform float uGrainAmount;
uniform float uVignetteAmount;
uniform float uChromaticAberration;
uniform float uBloomAmount;
uniform float uHalationAmount;

// ── RGB Channel Shift ─────────────────────────────────────────────────────
uniform float uColorBiasR;
uniform float uColorBiasG;
uniform float uColorBiasB;
uniform float uGrainSize;

// ── Inst C / SQC 共用参数 ─────────────────────────────────────────────────
uniform float uHighlightRolloff;
uniform float uPaperTexture;
uniform float uEdgeFalloff;
uniform float uExposureVariation;
uniform float uCornerWarmShift;

// ── SQC 专用参数 ──────────────────────────────────────────────────────────
uniform float uCenterGain;
uniform float uDevelopmentSoftness;
uniform float uChemicalIrregularity;
uniform float uSkinHueProtect;
uniform float uSkinSatProtect;
uniform float uSkinLumaSoften;
uniform float uSkinRedLimit;

// ─────────────────────────────────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────────────────────────────────

float sqcRandom(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

// SQC Tone Curve（Instax Square 曲线）
// 控制点：0→8, 32→36, 64→72, 128→134, 192→206, 255→246
float sqcToneCurve(float x) {
    if (x < 0.125) {
        float t = x / 0.125;
        float t2 = t * t; float t3 = t2 * t;
        return 0.031 + (0.141 - 0.031) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.251) {
        float t = (x - 0.125) / 0.126;
        float t2 = t * t; float t3 = t2 * t;
        return 0.141 + (0.282 - 0.141) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.502) {
        float t = (x - 0.251) / 0.251;
        float t2 = t * t; float t3 = t2 * t;
        return 0.282 + (0.525 - 0.282) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.753) {
        float t = (x - 0.502) / 0.251;
        float t2 = t * t; float t3 = t2 * t;
        return 0.525 + (0.808 - 0.525) * (3.0 * t2 - 2.0 * t3);
    } else {
        float t = (x - 0.753) / 0.247;
        float t2 = t * t; float t3 = t2 * t;
        return 0.808 + (0.965 - 0.808) * (3.0 * t2 - 2.0 * t3);
    }
}

// SQC 白平衡（正值偏暖，负值偏冷）
vec3 sqcWhiteBalance(vec3 c, float tempShift, float tintShift) {
    float ts = tempShift / 1000.0;
    float tt = tintShift / 1000.0;
    c.r = clamp(c.r + ts * 0.3 + tt * 0.15, 0.0, 1.0);
    c.g = clamp(c.g - tt * 0.08, 0.0, 1.0);
    c.b = clamp(c.b - ts * 0.3, 0.0, 1.0);
    return c;
}

// 肤色检测（基于 HSL 色相范围）
float sqcSkinMask(vec3 c) {
    float maxC = max(c.r, max(c.g, c.b));
    float minC = min(c.r, min(c.g, c.b));
    float delta = maxC - minC;
    if (delta < 0.05 || maxC < 0.15) return 0.0;
    float hue = 0.0;
    if (maxC == c.r) {
        hue = mod((c.g - c.b) / delta, 6.0);
    } else if (maxC == c.g) {
        hue = (c.b - c.r) / delta + 2.0;
    } else {
        hue = (c.r - c.g) / delta + 4.0;
    }
    hue = hue / 6.0;
    if (hue < 0.0) hue += 1.0;
    float sat = (maxC > 0.0) ? (delta / maxC) : 0.0;
    float lum = (maxC + minC) * 0.5;
    float inRange = 0.0;
    if ((hue < 0.10 || hue > 0.92) && sat > 0.10 && sat < 0.75 && lum > 0.25 && lum < 0.85) {
        inRange = smoothstep(0.0, 0.05, sat - 0.10) * smoothstep(0.0, 0.05, lum - 0.25);
    }
    return clamp(inRange, 0.0, 1.0);
}

// ─────────────────────────────────────────────────────────────────────────
// Main Fragment Shader
// ─────────────────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;
    vec2 center = vec2(0.5, 0.5);
    vec2 offset = uv - center;

    // ── Pass 1: Chromatic Aberration ────────────────────────────────────────
    float ca = uChromaticAberration * uTexelSize.x * 300.0;
    float r = texture(uCameraTexture, uv + vec2(ca, 0.0)).r;
    float g = texture(uCameraTexture, uv).g;
    float b = texture(uCameraTexture, uv - vec2(ca, 0.0)).b;
    vec3 color = vec3(r, g, b);

    // ── Pass 2: White Balance（暖粉感核心）──────────────────────────────────
    color = sqcWhiteBalance(color, uTemperatureShift, uTintShift);

    // ── Pass 3: Tone Curve（Instax Square 曲线）──────────────────────────────
    color.r = sqcToneCurve(color.r);
    color.g = sqcToneCurve(color.g);
    color.b = sqcToneCurve(color.b);

    // ── Pass 4: RGB Channel Shift（暖粉色偏）────────────────────────────────
    color.r = clamp(color.r + uColorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + uColorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + uColorBiasB, 0.0, 1.0);

    // ── Pass 5: Brightness Lift（整体提亮，闪光感）──────────────────────────
    float brightLift = 0.06;
    color = color + brightLift * (1.0 - color * 0.5);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 6: Saturation（更浓郁色彩）────────────────────────────────────
    float luma6 = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma6), color, uSaturation);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 7: Contrast（低对比，闪光感）──────────────────────────────────
    color = (color - 0.5) * uContrast + 0.5;
    color = clamp(color, 0.0, 1.0);

    // ── Pass 8: Highlight Rolloff（高光柔和压缩）────────────────────────────
    float rolloff = uHighlightRolloff;
    float threshold = 1.0 - rolloff;
    vec3 highMask = max(color - threshold, vec3(0.0));
    color = color - highMask * (1.0 - exp(-highMask / (rolloff + 0.001)));
    color = clamp(color, 0.0, 1.0);

    // ── Pass 9: Flash Bloom（闪光感柔光，SQC 核心特征）─────────────────────
    float luma9 = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float bloomMask = smoothstep(0.55, 0.85, luma9);
    vec3 bloomColor = vec3(1.0, 0.97, 0.92) * bloomMask * uBloomAmount;
    color = color + bloomColor * (1.0 - color);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 10: Halation（高光发光，闪光感）────────────────────────────────
    float luma10 = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float halMask = smoothstep(0.7, 1.0, luma10);
    vec3 halColor = vec3(1.0, 0.88, 0.80) * halMask * uHalationAmount;
    color = color + halColor * (1.0 - color * 0.6);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 11: Center Gain（中心主体增亮）─────────────────────────────────
    float dist = length(offset);
    float centerMask = 1.0 - smoothstep(0.0, 0.45, dist);
    color = color + centerMask * uCenterGain * (1.0 - color * 0.4);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 12: Fine Grain（轻颗粒）────────────────────────────────────────
    float noise12 = sqcRandom(uv, uTime) * 2.0 - 1.0;
    float luma12 = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float grainScale = uGrainAmount * (0.5 + 0.5 * (1.0 - luma12));
    color = color + noise12 * grainScale;
    color = clamp(color, 0.0, 1.0);

    // ── Pass 13: Paper Texture（相纸纤维纹理）───────────────────────────────
    vec2 paperUV = uv * vec2(120.0, 120.0);
    float paperNoise = sqcRandom(floor(paperUV) / 120.0, 42.0) * 2.0 - 1.0;
    color = color + paperNoise * uPaperTexture * 0.5;
    color = clamp(color, 0.0, 1.0);

    // ── Pass 14: Skin Tone Protection（肤色保护）────────────────────────────
    if (uSkinHueProtect > 0.5) {
        float skinMask = sqcSkinMask(color);
        if (skinMask > 0.01) {
            float lumaS = dot(color, vec3(0.2126, 0.7152, 0.0722));
            vec3 desatColor = vec3(lumaS);
            vec3 protectedColor = mix(desatColor, color, uSkinSatProtect);
            color = mix(color, protectedColor, skinMask);

            float lumaSoft = dot(color, vec3(0.2126, 0.7152, 0.0722));
            float softLift = uSkinLumaSoften * (1.0 - lumaSoft) * skinMask;
            color = color + softLift;

            color.r = min(color.r, color.g * uSkinRedLimit + color.b * 0.1);
            color = clamp(color, 0.0, 1.0);
        }
    }

    // ── Pass 15: Edge Falloff / Uneven Exposure（不均匀曝光）────────────────
    float edgeDist = length(offset);
    float edgeMask = smoothstep(0.0, 0.7, edgeDist);
    color = color * (1.0 - edgeMask * uEdgeFalloff);

    float expVar = sqcRandom(uv * 0.3, uTime * 0.1) * 2.0 - 1.0;
    color = color * (1.0 + expVar * uExposureVariation * 0.3);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 16: Development Softness（显影柔化）────────────────────────────
    float luma16 = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(color, vec3(luma16) * 0.3 + color * 0.7, uDevelopmentSoftness);
    color = clamp(color, 0.0, 1.0);

    // ── Pass 17: Chemical Irregularity（化学不规则感）───────────────────────
    vec2 irregUV = uv * 8.0;
    float irreg = sqcRandom(floor(irregUV) / 8.0, 99.0) * 2.0 - 1.0;
    vec3 irregShift = vec3(irreg * 0.6, irreg * 0.3, irreg * -0.4) * uChemicalIrregularity;
    color = color + irregShift;
    color = clamp(color, 0.0, 1.0);

    // ── Pass 18: Corner Warm Shift（边角偏暖）───────────────────────────────
    float cornerDist = length(offset);
    float cornerMask = smoothstep(0.3, 0.8, cornerDist);
    color.r = clamp(color.r + cornerMask * uCornerWarmShift * 0.6, 0.0, 1.0);
    color.b = clamp(color.b - cornerMask * uCornerWarmShift * 0.4, 0.0, 1.0);

    // ── Pass 19: Vignette（极轻暗角）────────────────────────────────────────
    float vigDist = length(offset);
    float vigMask = smoothstep(0.4, 1.0, vigDist);
    color = color * (1.0 - vigMask * uVignetteAmount * 1.5);
    color = clamp(color, 0.0, 1.0);

    fragColor = vec4(color, 1.0);
}
"""

    // ─────────────────────────────────────────────────────────────────────────
    // SQC 默认参数（与 sqc.json defaultLook 对应）
    // ─────────────────────────────────────────────────────────────────────────
    val DEFAULT_PARAMS = mapOf(
        // 通用参数
        "contrast"            to 0.88f,
        "saturation"          to 1.18f,
        "temperatureShift"    to 15.0f,
        "tintShift"           to 18.0f,
        "grainAmount"         to 0.06f,
        "vignette"            to 0.04f,
        "chromaticAberration" to 0.03f,
        "bloom"               to 0.14f,
        "halation"            to 0.06f,
        // RGB Channel Shift
        "colorBiasR"          to 0.035f,
        "colorBiasG"          to 0.008f,
        "colorBiasB"          to -0.025f,
        "grainSize"           to 1.6f,
        // Inst C / SQC 共用
        "highlightRolloff"    to 0.28f,
        "paperTexture"        to 0.05f,
        "edgeFalloff"         to 0.06f,
        "exposureVariation"   to 0.05f,
        "cornerWarmShift"     to 0.03f,
        // SQC 专用
        "centerGain"          to 0.03f,
        "developmentSoftness" to 0.04f,
        "chemicalIrregularity" to 0.02f,
        "skinHueProtect"      to 1.0f,
        "skinSatProtect"      to 0.95f,
        "skinLumaSoften"      to 0.04f,
        "skinRedLimit"        to 1.03f
    )
}
