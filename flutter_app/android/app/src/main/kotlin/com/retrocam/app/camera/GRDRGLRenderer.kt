package com.retrocam.app.camera

/**
 * GRDRGLRenderer — GRD-R (Ricoh GR Digital 街拍风格) GLSL Shader
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 风格定位：
 *   Ricoh GR Digital / GR II / GR III 街拍纪实风格
 *   核心气质：高锐度 + 冷中性 + 克制颜色 + 微对比
 *
 * 核心特征（基于 Ricoh GR 真实相机特性）：
 *   1. 高锐度（sharpen=0.12，sharpness=1.12）
 *   2. 冷白平衡（temperature=-20，偏蓝不偏暖）
 *   3. 低饱和（saturation=0.92，克制颜色）
 *   4. 微对比曲线（阴影压暗 + 中间调清晰 + 高光干净）
 *   5. Clarity 微对比（clarity=8，局部细节增强）
 *   6. 极低传感器非均匀性（数码相机，不是 instant）
 *   7. 肤色保护（低饱和容易让脸发灰）
 *   8. 无 halation，无 paperTexture，无 chemicalIrregularity
 *
 * GPU Pipeline 顺序（11 pass，比 instant 更简洁）：
 *   Camera Frame
 *   → Pass 0: Unsharp Mask 锐化（Ricoh GR 高锐度标志）
 *   → Pass 1: 色差（极轻微，0.05）
 *   → Pass 2: 白平衡（冷静，temperature=-20）
 *   → Pass 3: Highlight Rolloff（高光保护，0.10）
 *   → Pass 4: GRD-R Tone Curve（微对比曲线）
 *   → Pass 5: RGB 通道倾向（R-0.02, B+0.02）
 *   → Pass 6: 对比度 + 饱和度
 *   → Pass 7: Clarity / 微对比
 *   → Pass 8: 肤色保护
 *   → Pass 9: 传感器非均匀性 + 传感器噪声
 *   → Pass 10: 暗角（极轻微，0.05）
 *   → Output
 * ═══════════════════════════════════════════════════════════════════════════
 */
object GRDRGLRenderer {

    /**
     * GRD-R Fragment Shader（OpenGL ES 3.0）
     *
     * Tone Curve 控制点（GRD-R 微对比曲线）：
     *   Input:  0    16   32   64   96   128  160  192  224  255
     *   Output: 0    10   22   50   90   132  180  215  240  255
     * 特点：阴影压暗（-6）+ 中间调微提（+4）+ 高光干净
     */
    const val FRAGMENT_SHADER = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in  vec2 vTexCoord;
out vec4 fragColor;
uniform samplerExternalOES uCameraTexture;

// ── 通用参数（与 CameraGLRenderer 兼容）────────────────────────────────────
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

// ── GRD-R 专用 Uniform ──────────────────────────────────────────────────────
uniform float uColorBiasR;          // R 通道偏移（GRD-R=-0.02）
uniform float uColorBiasG;          // G 通道偏移（GRD-R=0.00）
uniform float uColorBiasB;          // B 通道偏移（GRD-R=+0.02）
uniform float uGrainSize;           // 颗粒大小（GRD-R=1.2）
uniform float uSharpness;           // 锐度倍数（GRD-R=1.12）
uniform float uHighlightRolloff;    // 高光柔和滚落（GRD-R=0.10）
uniform float uSharpen;             // Unsharp Mask 强度（GRD-R=0.12）
uniform float uEdgeFalloff;         // 边缘衰减（GRD-R=0.015）
uniform float uExposureVariation;   // 曝光波动（GRD-R=0.010）
uniform float uCornerWarmShift;     // 角落色温（GRD-R=-0.005）
uniform float uCenterGain;          // 中心增亮（GRD-R=0.005）
uniform float uLuminanceNoise;      // 亮度噪声（GRD-R=0.06）
uniform float uChromaNoise;         // 色度噪声（GRD-R=0.00）

// ── 肤色保护 Uniform ────────────────────────────────────────────────────────
uniform float uSkinHueProtect;      // 肤色保护（GRD-R=1.0）
uniform float uSkinSatProtect;      // 肤色饱和度保护（GRD-R=0.95）
uniform float uSkinLumaSoften;      // 肤色亮度柔化（GRD-R=0.02）
uniform float uSkinRedLimit;        // 肤色红限（GRD-R=1.03）

// ── 工具函数 ─────────────────────────────────────────────────────────────────

/// 伪随机数生成
float grdrRandom(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

/// GRD-R Tone Curve（微对比曲线）
/// 控制点（归一化）：
///   Input:  0      0.0627 0.1255 0.2510 0.3765 0.5020 0.6275 0.7529 0.8784 1.0
///   Output: 0      0.0392 0.0863 0.1961 0.3529 0.5176 0.7059 0.8431 0.9412 1.0
float grdrToneCurve(float x) {
    float inp[10];
    inp[0]=0.0; inp[1]=0.0627; inp[2]=0.1255; inp[3]=0.2510; inp[4]=0.3765;
    inp[5]=0.5020; inp[6]=0.6275; inp[7]=0.7529; inp[8]=0.8784; inp[9]=1.0;
    float outp[10];
    outp[0]=0.0; outp[1]=0.0392; outp[2]=0.0863; outp[3]=0.1961; outp[4]=0.3529;
    outp[5]=0.5176; outp[6]=0.7059; outp[7]=0.8431; outp[8]=0.9412; outp[9]=1.0;
    for (int i = 0; i < 9; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outp[i], outp[i + 1], t);
        }
    }
    return outp[9];
}

/// 白平衡（色温 + 色调）
vec3 grdrWhiteBalance(vec3 color, float tempShift, float tintShift) {
    float t = tempShift / 1000.0;
    float g = tintShift / 1000.0;
    color.r = clamp(color.r + t * 0.3, 0.0, 1.0);
    color.b = clamp(color.b - t * 0.3, 0.0, 1.0);
    color.g = clamp(color.g + g * 0.2, 0.0, 1.0);
    return color;
}

/// 对比度
vec3 grdrContrast(vec3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度
vec3 grdrSaturation(vec3 c, float sat) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(lum), c, sat), 0.0, 1.0);
}

/// Highlight Rolloff（高光保护）
vec3 grdrHighlightRolloff(vec3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.3;
    return clamp(color * compress, 0.0, 1.0);
}

/// Clarity / 微对比（局部对比度增强）
vec3 grdrClarity(vec3 color, vec2 uv, float clarityAmount) {
    if (clarityAmount <= 0.0) return color;
    vec2 texelSize = vec2(1.0 / 1080.0, 1.0 / 1440.0);
    vec3 blur = vec3(0.0);
    float weight = 0.0;
    for (int dx = -2; dx <= 2; dx++) {
        for (int dy = -2; dy <= 2; dy++) {
            float w = 1.0 / (1.0 + abs(float(dx)) + abs(float(dy)));
            blur += texture(uCameraTexture, uv + vec2(float(dx), float(dy)) * texelSize * 3.0).rgb * w;
            weight += w;
        }
    }
    blur /= weight;
    vec3 detail = color - blur;
    return clamp(color + detail * clarityAmount * 0.15, 0.0, 1.0);
}

/// 肤色保护（GRD-R 低饱和容易让脸发灰）
vec3 grdrSkinProtect(vec3 color, float protect, float satProt,
                     float lumaSoften, float redLimit) {
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
    float skinMask = smoothstep(0.0356, 0.0756, h) * (1.0 - smoothstep(0.105, 0.145, h));
    if (skinMask < 0.001) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    vec3 prot = mix(vec3(luma), color, satProt);
    prot = clamp(prot + lumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, redLimit);
    return mix(color, prot, skinMask);
}

/// 传感器非均匀性（中心增亮 + 边缘衰减）
float grdrCenterEdge(vec2 uv, float centerGain, float edgeFalloff) {
    vec2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

/// 角落色温偏移
vec3 grdrCornerWarm(vec2 uv, vec3 color, float shift) {
    vec2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor;
    color.r = clamp(color.r + s * 0.4, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.4, 0.0, 1.0);
    return color;
}

/// 暗角
float grdrVignette(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── 主函数 ───────────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;
    vec2 texelSize = vec2(1.0 / 1080.0, 1.0 / 1440.0);

    // === Pass 0: Unsharp Mask 锐化（Ricoh GR 高锐度标志）===
    vec3 color = texture(uCameraTexture, uv).rgb;
    if (uSharpen > 0.0) {
        vec3 blur =
            texture(uCameraTexture, uv + vec2(-texelSize.x, -texelSize.y)).rgb * 1.0 +
            texture(uCameraTexture, uv + vec2( 0.0,         -texelSize.y)).rgb * 2.0 +
            texture(uCameraTexture, uv + vec2( texelSize.x, -texelSize.y)).rgb * 1.0 +
            texture(uCameraTexture, uv + vec2(-texelSize.x,  0.0        )).rgb * 2.0 +
            color                                                          * 4.0 +
            texture(uCameraTexture, uv + vec2( texelSize.x,  0.0        )).rgb * 2.0 +
            texture(uCameraTexture, uv + vec2(-texelSize.x,  texelSize.y)).rgb * 1.0 +
            texture(uCameraTexture, uv + vec2( 0.0,          texelSize.y)).rgb * 2.0 +
            texture(uCameraTexture, uv + vec2( texelSize.x,  texelSize.y)).rgb * 1.0;
        blur /= 16.0;
        color = clamp(color + uSharpen * 2.0 * (color - blur), 0.0, 1.0);
    }

    // === Pass 1: 色差（极轻微，0.05）===
    if (uChromaticAberration > 0.0) {
        float ca = uChromaticAberration * texelSize.x * 20.0;
        float r = texture(uCameraTexture, uv + vec2(ca, 0.0)).r;
        float g = texture(uCameraTexture, uv).g;
        float b = texture(uCameraTexture, uv - vec2(ca, 0.0)).b;
        color = vec3(r, g, b);
    }

    // === Pass 2: 白平衡（冷静，temperature=-20）===
    color = grdrWhiteBalance(color, uTemperatureShift, uTintShift);

    // === Pass 3: Highlight Rolloff（高光保护，0.10）===
    color = grdrHighlightRolloff(color, uHighlightRolloff);

    // === Pass 4: GRD-R Tone Curve（微对比曲线，GRD-R 灵魂）===
    color.r = grdrToneCurve(color.r);
    color.g = grdrToneCurve(color.g);
    color.b = grdrToneCurve(color.b);

    // === Pass 5: RGB 通道倾向（冷静偏蓝）===
    color.r = clamp(color.r + uColorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + uColorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + uColorBiasB, 0.0, 1.0);

    // === Pass 6: 对比度 + 饱和度（contrast=1.10, sat=0.92）===
    color = grdrContrast(color, uContrast);
    color = grdrSaturation(color, uSaturation);

    // === Pass 7: Clarity / 微对比（clarity=8，GRD-R 灵魂之二）===
    float clarityNorm = 8.0 / 100.0;
    color = grdrClarity(color, uv, clarityNorm);

    // === Pass 8: 肤色保护（防止低饱和让脸发灰）===
    color = grdrSkinProtect(color,
        uSkinHueProtect, uSkinSatProtect,
        uSkinLumaSoften, uSkinRedLimit);

    // === Pass 9: 传感器非均匀性 + 传感器噪声 ===
    if (uCenterGain > 0.0 || uEdgeFalloff > 0.0) {
        float factor = grdrCenterEdge(uv, uCenterGain, uEdgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    if (uExposureVariation > 0.0) {
        float evn = grdrRandom(uv * 0.1, uTime * 0.01) - 0.5;
        color = clamp(color + evn * uExposureVariation * 0.3, 0.0, 1.0);
    }
    if (uCornerWarmShift != 0.0) {
        color = grdrCornerWarm(uv, color, uCornerWarmShift);
    }
    // 传感器噪声（亮度噪声，无色度噪声）
    if (uGrainAmount > 0.0) {
        float grain = grdrRandom(uv / max(uGrainSize, 0.1),
                                 floor(uTime * 24.0) / 24.0) - 0.5;
        color = clamp(color + grain * uGrainAmount * 0.2, 0.0, 1.0);
    }
    if (uLuminanceNoise > 0.0) {
        float ln = grdrRandom(uv, uTime + 1.7) - 0.5;
        color = clamp(color + ln * uLuminanceNoise * 0.12, 0.0, 1.0);
    }

    // === Pass 10: 暗角（极轻微，0.05）===
    if (uVignetteAmount > 0.0) {
        color *= grdrVignette(uv, uVignetteAmount);
    }

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
"""
}
