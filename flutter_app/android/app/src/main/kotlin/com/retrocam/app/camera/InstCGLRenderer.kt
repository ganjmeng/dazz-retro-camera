package com.retrocam.app.camera

/**
 * InstCGLRenderer — Inst C (Instax / Polaroid 风格即时成像机) GLSL Shader
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 风格定位：
 *   Fujifilm Instax Mini / Instax Square / Polaroid 混合型 instant preset
 *   社区定义：digital Polaroid / instant nostalgia / Polaroid-style output
 *
 * 核心特征：
 *   1. 低到中对比（contrast=0.92）
 *   2. 轻暖白平衡（temperature=+6400K）
 *   3. 轻微洋红（tint=+6）
 *   4. 高光柔和 rolloff（highlightRolloff=0.20）
 *   5. 轻微不均匀曝光（edgeFalloff=0.05, exposureVariation=0.04）
 *   6. 轻纸感纹理（paperTexture=0.06）
 *   7. 轻颗粒（grain=0.08，非胶片重颗粒）
 *
 * GPU Pipeline 顺序：
 *   Camera Frame
 *   → White Balance（色温 + Tint）
 *   → Tone Curve（Instax 胶片曲线）
 *   → RGB Channel Shift（暖调色偏）
 *   → Saturation + Contrast
 *   → Highlight Rolloff（高光柔和滴落）
 *   → Soft Bloom（轻柔光）
 *   → Halation（极轻高光发光）
 *   → Fine Grain（轻颗粒，grain_color=false）
 *   → Paper Texture（相纸纹理）
 *   → Edge Falloff / Uneven Exposure（不均匀曝光）
 *   → Vignette（极轻暗角）
 *   → Output
 *
 * 新增 Uniform（相比 CameraGLRenderer 的基础 Shader）：
 *   uColorBiasR/G/B   — RGB 通道偏移（Instax 暖调色偏）
 *   uGrainSize        — 颗粒大小（Inst C=1.8）
 *   uSharpness        — 锐度倍数（Inst C=0.98）
 *   uHighlightRolloff — 高光柔和滴落（Inst C=0.20）
 *   uPaperTexture     — 相纸纹理强度（Inst C=0.06）
 *   uEdgeFalloff      — 边缘曝光衰减（Inst C=0.05）
 *   uExposureVariation — 曝光不均匀幅度（Inst C=0.04）
 *   uCornerWarmShift  — 边角偏暖强度（Inst C=0.02）
 * ═══════════════════════════════════════════════════════════════════════════
 */
object InstCShaderSource {

    /**
     * Inst C Fragment Shader（OpenGL ES 3.0）
     *
     * Tone Curve 控制点（归一化）：
     *   (0, 0.024) (0.125, 0.133) (0.251, 0.267) (0.502, 0.510) (0.753, 0.792) (1.0, 0.973)
     * 对应原始值：0→6, 32→34, 64→68, 128→130, 192→202, 255→248
     * 效果：黑位抬一点，中间调偏软，高光轻 rolloff，更像即时成像
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

// ── Inst C 专用 Uniform ─────────────────────────────────────────────────────
uniform float uColorBiasR;          // R 通道偏移（Inst C=+0.022）
uniform float uColorBiasG;          // G 通道偏移（Inst C=+0.010）
uniform float uColorBiasB;          // B 通道偏移（Inst C=-0.015）
uniform float uGrainSize;           // 颗粒大小（Inst C=1.8）
uniform float uSharpness;           // 锐度倍数（Inst C=0.98）
uniform float uHighlightRolloff;    // 高光柔和滴落（Inst C=0.20）
uniform float uPaperTexture;        // 相纸纹理强度（Inst C=0.06）
uniform float uEdgeFalloff;         // 边缘曝光衰减（Inst C=0.05）
uniform float uExposureVariation;   // 曝光不均匀幅度（Inst C=0.04）
uniform float uCornerWarmShift;     // 边角偏暖强度（Inst C=0.02）

// ── 工具函数 ─────────────────────────────────────────────────────────────────

/// 伪随机数生成（基于 UV + 时间种子）
float instcRandom(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

/// Inst C Tone Curve（Instax 胶片曲线）
/// 控制点：0→6, 32→34, 64→68, 128→130, 192→202, 255→248（归一化）
/// 效果：黑位抬一点，中间调偏软，高光轻 rolloff
float instcToneCurve(float x) {
    if (x < 0.125) {
        float t = x / 0.125;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.024 + (0.133 - 0.024) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.251) {
        float t = (x - 0.125) / 0.126;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.133 + (0.267 - 0.133) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.502) {
        float t = (x - 0.251) / 0.251;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.267 + (0.510 - 0.267) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.753) {
        float t = (x - 0.502) / 0.251;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.510 + (0.792 - 0.510) * (3.0 * t2 - 2.0 * t3);
    } else {
        // 高光轻 rolloff
        float t = (x - 0.753) / 0.247;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.792 + (0.973 - 0.792) * (3.0 * t2 - 2.0 * t3);
    }
}

/// 饱和度调整（HSL 空间）
vec3 instcSaturation(vec3 color, float saturation) {
    float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(lum), color, saturation), 0.0, 1.0);
}

/// 对比度调整（以 0.5 为中心）
vec3 instcContrast(vec3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 色温 + Tint 调整（Instax 冷白调）
/// 正值 = 偏暖（加R减B），负值 = 偏冷（减R加B）
/// Instax 实际偏冷白，所以 temperature = -20
vec3 instcTemperatureTint(vec3 color, float temperature, float tint) {
    // 色温：与通用 Shader 保持一致，/1000 缩放
    float tempFactor = temperature / 1000.0;  // -20 → -0.02
    color.r = clamp(color.r + tempFactor * 0.30, 0.0, 1.0);
    color.g = clamp(color.g + tempFactor * 0.05, 0.0, 1.0);
    color.b = clamp(color.b - tempFactor * 0.25, 0.0, 1.0);
    // Tint：正值偏洋红（R+, G-）
    float tintFactor = tint * 0.002;          // +6 → +0.012
    color.r = clamp(color.r + tintFactor * 0.5, 0.0, 1.0);
    color.g = clamp(color.g - tintFactor * 0.3, 0.0, 1.0);
    color.b = clamp(color.b + tintFactor * 0.1, 0.0, 1.0);
    return color;
}

/// Highlight Rolloff（高光柔和滴落）
/// 将高光区域（lum > 0.7）柔和压缩，避免过曝死白
vec3 instcHighlightRolloff(vec3 color, float rolloff) {
    if (rolloff < 0.001) return color;
    float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    if (lum > 0.70) {
        float mask = clamp((lum - 0.70) / 0.30, 0.0, 1.0);
        mask = mask * mask * (3.0 - 2.0 * mask);  // smoothstep
        // 压缩高光（偏暖：R 保留更多，B 压缩更多）
        vec3 compressed = vec3(
            color.r * (1.0 - mask * rolloff * 0.15),
            color.g * (1.0 - mask * rolloff * 0.20),
            color.b * (1.0 - mask * rolloff * 0.30)
        );
        color = mix(color, compressed, mask * rolloff);
    }
    return clamp(color, 0.0, 1.0);
}

/// Vignette（暗角，Instax 极轻）
float instcVignette(vec2 uv, float amount) {
    vec2 center = uv - 0.5;
    float dist = length(center * vec2(1.0, 1.3));  // 椭圆形暗角
    float vignette = 1.0 - smoothstep(0.3, 0.85, dist * 1.8);
    return mix(1.0, vignette, amount);
}

/// Edge Falloff（边缘曝光衰减，模拟 Instax 不均匀曝光）
float instcEdgeFalloff(vec2 uv, float amount, float time) {
    if (amount < 0.001) return 1.0;
    vec2 center = uv - 0.5;
    // 基础边缘衰减（椭圆形）
    float edgeDist = dot(center * vec2(1.2, 1.0), center * vec2(1.2, 1.0));
    float falloff = 1.0 - smoothstep(0.10, 0.35, edgeDist);
    // 轻微不均匀（低频噪声模拟化学显影不均）
    float variation = instcRandom(uv * 0.3, floor(time * 0.1)) * 2.0 - 1.0;
    variation *= 0.3;
    falloff = clamp(falloff + variation * amount * 0.5, 0.6, 1.0);
    return mix(1.0, falloff, amount * 1.5);
}

/// Corner Warm Shift（边角偏暖，Instax 化学显影边缘特征）
vec3 instcCornerWarm(vec3 color, vec2 uv, float amount) {
    if (amount < 0.001) return color;
    vec2 center = uv - 0.5;
    float dist = length(center);
    float cornerMask = smoothstep(0.25, 0.55, dist);
    // 边角偏暖：R+, B-
    color.r = clamp(color.r + cornerMask * amount * 0.08, 0.0, 1.0);
    color.b = clamp(color.b - cornerMask * amount * 0.06, 0.0, 1.0);
    return color;
}

/// Paper Texture（相纸纹理，模拟 Instax 相纸表面微纹理）
vec3 instcPaperTexture(vec3 color, vec2 uv, float amount) {
    if (amount < 0.001) return color;
    // 相纸纹理：低频 + 高频叠加，模拟纸张纤维
    vec2 paperUV1 = uv * 8.0;
    vec2 paperUV2 = uv * 32.0;
    float paper1 = instcRandom(paperUV1, 0.0) * 2.0 - 1.0;
    float paper2 = instcRandom(paperUV2, 1.0) * 2.0 - 1.0;
    float paper = paper1 * 0.7 + paper2 * 0.3;
    // 纸纹叠加（亮度通道，不影响色彩）
    vec3 paperColor = color + vec3(paper * amount * 0.04);
    return clamp(paperColor, 0.0, 1.0);
}

// ── 主函数 ──────────────────────────────────────────────────────────────────

void main() {
    vec2 uv = vTexCoord;

    // ── Pass 1: 采样（Inst C 色差极轻）──────────────────────────────────────
    vec3 color;
    if (uChromaticAberration > 0.001) {
        float ca = uChromaticAberration * 0.008;
        float r = texture(uCameraTexture, uv + vec2(ca,  0.0)).r;
        float g = texture(uCameraTexture, uv).g;
        float b = texture(uCameraTexture, uv - vec2(ca,  0.0)).b;
        color = vec3(r, g, b);
    } else {
        color = texture(uCameraTexture, uv).rgb;
    }

    // ── Pass 2: 白平衡（色温 + Tint，Instax 轻暖调）─────────────────────────
    color = instcTemperatureTint(color, uTemperatureShift, uTintShift);

    // ── Pass 3: Tone Curve（Instax 胶片曲线）────────────────────────────────
    color.r = instcToneCurve(color.r);
    color.g = instcToneCurve(color.g);
    color.b = instcToneCurve(color.b);

    // ── Pass 4: RGB Channel Shift（Instax 暖调色偏）─────────────────────────
    color.r = clamp(color.r * (1.0 + uColorBiasR), 0.0, 1.0);
    color.g = clamp(color.g * (1.0 + uColorBiasG), 0.0, 1.0);
    color.b = clamp(color.b * (1.0 + uColorBiasB), 0.0, 1.0);

    // ── Pass 5: 饱和度（1.08，Instax 色彩略浓）──────────────────────────────
    color = instcSaturation(color, uSaturation);

    // ── Pass 6: 对比度（0.92，低对比 Instax 感）─────────────────────────────
    color = instcContrast(color, uContrast);

    // ── Pass 7: Highlight Rolloff（高光柔和滴落，Inst C 核心特征）──────────
    color = instcHighlightRolloff(color, uHighlightRolloff);

    // ── Pass 8: Soft Bloom（轻柔光，高光偏柔）───────────────────────────────
    float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    if (uBloomAmount > 0.001 && lum > 0.75) {
        float bloom = clamp((lum - 0.75) * uBloomAmount * 2.5, 0.0, 0.25);
        // Instax bloom 偏暖白（R > G > B）
        color = clamp(color + vec3(bloom * 0.9, bloom * 0.8, bloom * 0.6), 0.0, 1.0);
    }

    // ── Pass 9: Halation（极轻高光发光，Inst C=0.02）────────────────────────
    if (uHalationAmount > 0.001 && lum > 0.80) {
        float halationMask = clamp((lum - 0.80) / 0.20, 0.0, 1.0);
        halationMask = halationMask * halationMask;
        // Instax halation 偏暖白（不像胶片那么红）
        vec3 halationColor = vec3(
            color.r * 1.08,
            color.g * 1.02,
            color.b * 0.95
        );
        color = mix(color, halationColor, halationMask * uHalationAmount);
    }

    // ── Pass 10: Fine Grain（轻颗粒，grain_color=false）─────────────────────
    if (uGrainAmount > 0.001) {
        float timeSeed = floor(uTime * 24.0) / 24.0;  // 锁定 24fps
        // 亮度颗粒（grain_color=false，Instax 颗粒不彩色）
        float grain = instcRandom(uv * max(uGrainSize, 0.1), timeSeed) - 0.5;
        // 颗粒强度随亮度变化（中间调最明显）
        float grainLum = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float grainMask = 1.0 - abs(grainLum - 0.50) * 1.0;
        grainMask = clamp(grainMask, 0.2, 1.0);
        color = clamp(color + vec3(grain) * uGrainAmount * 0.18 * grainMask, 0.0, 1.0);
    }

    // ── Pass 11: Paper Texture（相纸纹理）───────────────────────────────────
    color = instcPaperTexture(color, uv, uPaperTexture);

    // ── Pass 12: Edge Falloff / Uneven Exposure（不均匀曝光，Inst C 核心特征）
    float edgeFactor = instcEdgeFalloff(uv, uEdgeFalloff, uTime);
    color *= edgeFactor;

    // ── Pass 13: Corner Warm Shift（边角偏暖）───────────────────────────────
    color = instcCornerWarm(color, uv, uCornerWarmShift);

    // ── Pass 14: Vignette（极轻暗角，Inst C=0.06）───────────────────────────
    if (uVignetteAmount > 0.001) {
        color *= instcVignette(uv, uVignetteAmount);
    }

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
"""

    /**
     * Inst C 默认参数值（对应 inst_c.json 的 defaultLook）
     * 在 CameraGLRenderer.updateParams() 中通过 key 传入
     */
    val DEFAULT_PARAMS = mapOf(
        "contrast"            to 0.92f,
        "saturation"          to 1.08f,
        "temperatureShift"    to -20.0f,   // Instax 偏冷白，负值偏冷
        "tintShift"           to 6.0f,
        "chromaticAberration" to 0.05f,
        "vignette"            to 0.06f,
        "grain"               to 0.08f,
        "bloom"               to 0.06f,
        "halation"            to 0.02f,
        // Inst C 专有参数
        "colorBiasR"          to  0.022f,
        "colorBiasG"          to  0.010f,
        "colorBiasB"          to -0.015f,
        "grainSize"           to  1.8f,
        "sharpness"           to  0.98f,
        "highlightRolloff"    to  0.20f,
        "paperTexture"        to  0.06f,
        "edgeFalloff"         to  0.05f,
        "exposureVariation"   to  0.04f,
        "cornerWarmShift"     to  0.02f
    )
}
