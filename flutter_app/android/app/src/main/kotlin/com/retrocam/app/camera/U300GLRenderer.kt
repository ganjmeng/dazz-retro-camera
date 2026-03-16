package com.retrocam.app.camera

/**
 * U300GLRenderer — U300 (Kodak UltraMax 400 一次性胶卷相机) GLSL Shader
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 风格定位：
 *   Kodak UltraMax 400 + Kodak FunSaver 一次性胶卷相机
 *   核心气质：暖橙 + 粗颗粒 + 胶片高光 + Kodak 肤色
 *
 * 核心特征（基于 Kodak UltraMax 400 真实胶片特性）：
 *   1. 暖橙色调（temperature=40，Kodak 标志性暖黄橙）
 *   2. R 通道偏强（colorBiasR=+0.055，Kodak 红色饱满）
 *   3. B 通道压暗（colorBiasB=-0.045，天空偏暖非冷蓝）
 *   4. 粗颗粒（grain=0.22, grainSize=1.5，400 度胶片）
 *   5. 彩色噪声（chromaNoise=0.06，Kodak 400 特征）
 *   6. 胶片高光 rolloff（highlightRolloff=0.15）
 *   7. 化学显影柔化（developmentSoftness=0.03）
 *   8. 化学不规则感（chemicalIrregularity=0.025）
 *   9. 廉价镜头色差（chromaticAberration=0.09）
 *  10. 肤色保护（skinRedLimit=1.05，防止 Kodak 肤色过橙）
 *
 * GPU Pipeline 顺序（14 pass，镜像 iOS U300Shader.metal）：
 *   Camera Frame
 *   → Pass 0: 色差（廉价镜头，0.09）
 *   → Pass 1: 白平衡（暖橙，temperature=40）
 *   → Pass 2: Highlight Rolloff（胶片高光保护，0.15）
 *   → Pass 3: Kodak Tone Curve（正片感曲线）
 *   → Pass 4: RGB 通道倾向（R+0.055, G+0.018, B-0.045）
 *   → Pass 5: 对比度 + 饱和度
 *   → Pass 6: 胶片 Halation（极轻，0.03）
 *   → Pass 7: 肤色保护（防止 Kodak 肤色过橙）
 *   → Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减）
 *   → Pass 9: 化学显影柔化（developmentSoftness=0.03）
 *   → Pass 10: 化学不规则感（chemicalIrregularity=0.025）
 *   → Pass 11: 粗颗粒（grain=0.22, grainSize=1.5）
 *   → Pass 12: 彩色噪声（chromaNoise=0.06）
 *   → Pass 13: 暗角（vignette=0.16）
 *   → Output
 * ═══════════════════════════════════════════════════════════════════════════
 */
object U300GLRenderer {

    /**
     * U300 Fragment Shader（OpenGL ES 3.0）
     *
     * Kodak UltraMax 400 Tone Curve 控制点（归一化）：
     *   Input:  0      0.063  0.125  0.251  0.502  0.627  0.878  1.0
     *   Output: 0      0.047  0.110  0.235  0.518  0.680  0.910  0.975
     * 特点：阴影轻压 + 中间调轻提 + 高光亮但不溢（Kodak 正片感）
     */
    const val FRAGMENT_SHADER = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in  vec2 vTexCoord;
out vec4 fragColor;
uniform samplerExternalOES uCameraTexture;

// ── 通用参数 ────────────────────────────────────────────────────────────────
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift;
uniform float uTintShift;
uniform float uGrainAmount;
uniform float uVignetteAmount;
uniform float uChromaticAberration;
uniform float uBloomAmount;
uniform float uHalationAmount;
uniform float uTime;

// ── U300 专用 Uniform ───────────────────────────────────────────────────────
uniform float uColorBiasR;          // R 通道偏移（U300=+0.055）
uniform float uColorBiasG;          // G 通道偏移（U300=+0.018）
uniform float uColorBiasB;          // B 通道偏移（U300=-0.045）
uniform float uGrainSize;           // 颗粒大小（U300=1.5）
uniform float uSharpness;           // 锐度倍数（U300=1.02）
uniform float uHighlightRolloff;    // 高光柔和滴落（U300=0.15）
uniform float uEdgeFalloff;         // 边缘曝光衰减（U300=0.05）
uniform float uExposureVariation;   // 曝光波动（U300=0.04）
uniform float uCornerWarmShift;     // 角落偏暖（U300=0.025）
uniform float uCenterGain;          // 中心增亮（U300=0.015）
uniform float uDevelopmentSoftness; // 化学显影柔化（U300=0.03）
uniform float uChemicalIrregularity;// 化学不规则感（U300=0.025）
uniform float uLuminanceNoise;      // 亮度噪声（U300=0.10）
uniform float uChromaNoise;         // 彩色噪声（U300=0.06）

// ── 肤色保护 Uniform ────────────────────────────────────────────────────────
uniform float uSkinHueProtect;      // 肤色保护（U300=1.0）
uniform float uSkinSatProtect;      // 肤色饱和度保护（U300=0.90）
uniform float uSkinLumaSoften;      // 肤色亮度柔化（U300=0.04）
uniform float uSkinRedLimit;        // 肤色红限（U300=1.05）

// ── 工具函数 ─────────────────────────────────────────────────────────────────

/// 伪随机数
float u300Random(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

/// 白平衡
vec3 u300WhiteBalance(vec3 c, float tempShift, float tintShift) {
    float t = tempShift / 1000.0;
    float g = tintShift / 1000.0;
    c.r = clamp(c.r + t * 0.3, 0.0, 1.0);
    c.b = clamp(c.b - t * 0.3, 0.0, 1.0);
    c.g = clamp(c.g + g * 0.2, 0.0, 1.0);
    return c;
}

/// Kodak UltraMax 400 Tone Curve（正片感曲线）
float u300ToneCurve(float x) {
    float inp[8];
    inp[0]=0.0; inp[1]=0.063; inp[2]=0.125; inp[3]=0.251;
    inp[4]=0.502; inp[5]=0.627; inp[6]=0.878; inp[7]=1.0;
    float outp[8];
    outp[0]=0.0; outp[1]=0.047; outp[2]=0.110; outp[3]=0.235;
    outp[4]=0.518; outp[5]=0.680; outp[6]=0.910; outp[7]=0.975;
    for (int i = 0; i < 7; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outp[i], outp[i + 1], t);
        }
    }
    return outp[7];
}

/// 对比度
vec3 u300Contrast(vec3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度
vec3 u300Saturation(vec3 c, float sat) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(lum), c, sat), 0.0, 1.0);
}

/// Highlight Rolloff（胶片高光保护）
vec3 u300HighlightRolloff(vec3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.35;
    return clamp(color * compress, 0.0, 1.0);
}

/// Halation（胶片高光发光，偏橙红）
vec3 u300Halation(vec3 color, float amount) {
    if (amount <= 0.0) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float highlight = clamp((luma - 0.75) / 0.25, 0.0, 1.0);
    vec3 halationColor = vec3(1.0, 0.55, 0.2);
    return clamp(color + halationColor * highlight * amount * 0.4, 0.0, 1.0);
}

/// 肤色保护（防止 Kodak 暖调让肤色过橙）
vec3 u300SkinProtect(vec3 color, float protect,
                     float satProt, float lumaSoften, float redLimit) {
    if (protect < 0.5) return color;
    float maxC = max(max(color.r, color.g), color.b);
    float minC = min(min(color.r, color.g), color.b);
    float delta = maxC - minC;
    float h = 0.0;
    if (delta > 0.001) {
        if (maxC == color.r)      h = mod((color.g - color.b) / delta, 6.0);
        else if (maxC == color.g) h = (color.b - color.r) / delta + 2.0;
        else                      h = (color.r - color.g) / delta + 4.0;
        h = h / 6.0;
        if (h < 0.0) h += 1.0;
    }
    // 偏橙肤色范围（0.03-0.12）
    float skinMask = smoothstep(0.030, 0.065, h) * (1.0 - smoothstep(0.100, 0.140, h));
    if (skinMask < 0.001) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    vec3 prot = mix(vec3(luma), color, satProt);
    prot = clamp(prot + lumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, redLimit);
    return mix(color, prot, skinMask);
}

/// 传感器非均匀性（中心增亮 + 边缘衰减）
float u300CenterEdge(vec2 uv, float centerGain, float edgeFalloff) {
    vec2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

/// 角落偏暖（Kodak 边角暖橙特征）
vec3 u300CornerWarm(vec2 uv, vec3 color, float shift) {
    vec2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor;
    color.r = clamp(color.r + s * 0.5, 0.0, 1.0);
    color.g = clamp(color.g + s * 0.2, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.3, 0.0, 1.0);
    return color;
}

/// 暗角
float u300Vignette(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── 主函数 ───────────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;
    vec2 texelSize = vec2(1.0 / 1080.0, 1.0 / 1440.0);

    // === Pass 0: 色差（廉价镜头，0.09）===
    vec3 color;
    if (uChromaticAberration > 0.0) {
        float ca = uChromaticAberration * texelSize.x * 20.0;
        float r = texture(uCameraTexture, uv + vec2(ca, 0.0)).r;
        float g = texture(uCameraTexture, uv).g;
        float b = texture(uCameraTexture, uv - vec2(ca, 0.0)).b;
        color = vec3(r, g, b);
    } else {
        color = texture(uCameraTexture, uv).rgb;
    }

    // === Pass 1: 白平衡（暖橙，temperature=40）===
    color = u300WhiteBalance(color, uTemperatureShift, uTintShift);

    // === Pass 2: Highlight Rolloff（胶片高光保护，0.15）===
    color = u300HighlightRolloff(color, uHighlightRolloff);

    // === Pass 3: Kodak Tone Curve（正片感曲线）===
    color.r = u300ToneCurve(color.r);
    color.g = u300ToneCurve(color.g);
    color.b = u300ToneCurve(color.b);

    // === Pass 4: RGB 通道倾向（R+0.055, G+0.018, B-0.045）===
    color.r = clamp(color.r + uColorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + uColorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + uColorBiasB, 0.0, 1.0);

    // === Pass 5: 对比度 + 饱和度（contrast=0.96, sat=1.10）===
    color = u300Contrast(color, uContrast);
    color = u300Saturation(color, uSaturation);

    // === Pass 6: 胶片 Halation（极轻，0.03）===
    color = u300Halation(color, uHalationAmount);

    // === Pass 7: 肤色保护（防止 Kodak 肤色过橙）===
    color = u300SkinProtect(color,
        uSkinHueProtect, uSkinSatProtect,
        uSkinLumaSoften, uSkinRedLimit);

    // === Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减）===
    if (uCenterGain > 0.0 || uEdgeFalloff > 0.0) {
        float factor = u300CenterEdge(uv, uCenterGain, uEdgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    if (uExposureVariation > 0.0) {
        float evn = u300Random(uv * 0.1, uTime * 0.01) - 0.5;
        color = clamp(color + evn * uExposureVariation * 0.3, 0.0, 1.0);
    }
    if (uCornerWarmShift > 0.0) {
        color = u300CornerWarm(uv, color, uCornerWarmShift);
    }

    // === Pass 9: 化学显影柔化（developmentSoftness=0.03）===
    if (uDevelopmentSoftness > 0.0) {
        vec3 blurred =
            texture(uCameraTexture, uv + vec2(-texelSize.x, 0.0)).rgb * 0.25 +
            texture(uCameraTexture, uv + vec2( texelSize.x, 0.0)).rgb * 0.25 +
            texture(uCameraTexture, uv + vec2(0.0, -texelSize.y)).rgb * 0.25 +
            texture(uCameraTexture, uv + vec2(0.0,  texelSize.y)).rgb * 0.25;
        color = mix(color, blurred, uDevelopmentSoftness * 0.5);
    }

    // === Pass 10: 化学不规则感（chemicalIrregularity=0.025）===
    if (uChemicalIrregularity > 0.0) {
        vec2 blockUV = floor(uv * 64.0) / 64.0;
        float irr = (u300Random(blockUV, 0.42) - 0.5) * uChemicalIrregularity;
        color = clamp(color + irr * 0.6, 0.0, 1.0);
    }

    // === Pass 11: 粗颗粒（grain=0.22, grainSize=1.5）===
    if (uGrainAmount > 0.0) {
        vec2 grainUV = uv / max(uGrainSize * 0.003, 0.001);
        float grain = u300Random(grainUV, floor(uTime * 24.0) / 24.0) - 0.5;
        // 暗部颗粒更明显（Kodak 400 特征）
        float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float darkBoost = 1.0 + (1.0 - luma) * 0.8;
        color = clamp(color + grain * uGrainAmount * 0.25 * darkBoost, 0.0, 1.0);
    }

    // === Pass 12: 彩色噪声（chromaNoise=0.06，Kodak 400 特征）===
    if (uChromaNoise > 0.0) {
        vec2 cnUV = uv / max(uGrainSize * 0.004, 0.001);
        float cr = (u300Random(cnUV, 1.1) - 0.5) * uChromaNoise * 0.15;
        float cg = (u300Random(cnUV, 2.3) - 0.5) * uChromaNoise * 0.10;
        float cb = (u300Random(cnUV, 3.7) - 0.5) * uChromaNoise * 0.12;
        color = clamp(color + vec3(cr, cg, cb), 0.0, 1.0);
    }

    // === Pass 13: 暗角（vignette=0.16）===
    if (uVignetteAmount > 0.0) {
        color *= u300Vignette(uv, uVignetteAmount);
    }

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
"""
}
