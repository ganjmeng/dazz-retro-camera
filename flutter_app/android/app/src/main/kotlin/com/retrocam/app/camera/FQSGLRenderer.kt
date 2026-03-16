package com.retrocam.app.camera

/**
 * FQSGLRenderer — Fuji Superia 400 + Kodak Portra 400 GLSL Shader
 *
 * 这是 FQS 相机模式的专用 OpenGL ES 3.0 渲染器。
 * 继承自 CameraGLRenderer 的架构，但使用独立的 FRAGMENT_SHADER 实现
 * FQS 特有的色彩科学管线。
 *
 * FQS Pipeline 顺序：
 *   Camera Frame
 *   → Chromatic Aberration（色差）
 *   → Tone Curve（胶片曲线）
 *   → RGB Channel Shift（Fuji Superia 色偏：R-4%, G+5%, B+2%）
 *   → Saturation（饱和度 1.05）
 *   → Contrast（对比度 0.92，低对比胶片感）
 *   → Temperature + Tint（色温 -40K，Tint -18 偏绿）
 *   → Skin Tone Guard（Kodak Portra 肤色保护）
 *   → Halation（高光发光，模拟胶片高光溢出）
 *   → Bloom（柔光）
 *   → Film Grain（胶片颗粒，grain_intensity=0.28, grain_size=1.8, grain_color=true）
 *   → Luminance Noise + Chroma Noise（胶片扫描噪声）
 *   → Vignette（暗角 0.15）
 *   → Output
 *
 * FQS 成功复刻三要素（缺一不可）：
 *   1. Fuji Green Tone  — G+5%, 中间调微绿
 *   2. Soft Contrast    — 胶片曲线压低阴影、抬高中间调
 *   3. Film Grain       — 彩色颗粒，grain_intensity=0.28
 */
object FQSShaderSource {

    /**
     * FQS Fragment Shader（OpenGL ES 3.0）
     *
     * 新增 Uniform（相比 CameraGLRenderer 的基础 Shader）：
     *   uColorBiasR/G/B  — RGB 通道偏移（Fuji Superia 色偏）
     *   uHalationAmount  — 高光发光强度
     *   uBloomAmount     — 柔光强度
     *   uGrainSize       — 颗粒大小（控制 UV 缩放）
     *   uTintShift       — Tint 偏移（偏绿）
     *   uLuminanceNoise  — 亮度噪声强度
     *   uChromaNoise     — 色度噪声强度
     */
    const val FRAGMENT_SHADER = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;

in  vec2 vTexCoord;
out vec4 fragColor;

uniform samplerExternalOES uCameraTexture;

// ── 基础参数（与 CameraGLRenderer 兼容）────────────────────────────
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift;
uniform float uChromaticAberration;
uniform float uVignetteAmount;
uniform float uGrainAmount;
uniform float uTime;
uniform vec2  uTexelSize;

// ── FQS 专有参数 ────────────────────────────────────────────────────
uniform float uColorBiasR;       // RGB Channel Shift R（推荐 -0.04）
uniform float uColorBiasG;       // RGB Channel Shift G（推荐 +0.05）
uniform float uColorBiasB;       // RGB Channel Shift B（推荐 +0.02）
uniform float uTintShift;        // Tint 偏移（推荐 -18，偏绿）
uniform float uHalationAmount;   // 高光发光（推荐 0.15）
uniform float uBloomAmount;      // 柔光（推荐 0.10）
uniform float uGrainSize;        // 颗粒大小（推荐 1.8）
uniform float uLuminanceNoise;   // 亮度噪声（推荐 0.08）
uniform float uChromaNoise;      // 色度噪声（推荐 0.05）

// ── 工具函数 ────────────────────────────────────────────────────────

float fqsRandom(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

// FQS 胶片 Tone Curve（分段三次平滑插值）
// 控制点（归一化）：
//   (0.000, 0.000) (0.125, 0.110) (0.251, 0.227)
//   (0.502, 0.471) (0.753, 0.804) (1.000, 1.000)
float fqsToneCurve(float v) {
    v = clamp(v, 0.0, 1.0);
    float t;

    if (v <= 0.12549) {
        t = v / 0.12549;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.0, 0.10980, t);
    } else if (v <= 0.25098) {
        t = (v - 0.12549) / 0.12549;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.10980, 0.22745, t);
    } else if (v <= 0.50196) {
        t = (v - 0.25098) / 0.25098;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.22745, 0.47059, t);
    } else if (v <= 0.75294) {
        t = (v - 0.50196) / 0.25098;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.47059, 0.80392, t);
    } else {
        t = (v - 0.75294) / 0.24706;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.80392, 1.0, t);
    }
}

vec3 fqsContrast(vec3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

vec3 fqsSaturation(vec3 c, float sat) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(lum), c, sat), 0.0, 1.0);
}

// 色温 + Tint（简化 RGB 空间实现，与 iOS Metal 版本保持一致）
// 正值 = 偏暖（加R减B），负值 = 偏冷（减R加B）
vec3 fqsTemperatureTint(vec3 c, float tempShift, float tintShift) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float strength = lum * 0.8 + 0.2;
    float ts = tempShift / 1000.0;
    c.r = clamp(c.r + ts *  0.018 * strength, 0.0, 1.0);
    c.b = clamp(c.b - ts *  0.022 * strength, 0.0, 1.0);
    // Tint：负值偏绿，中间调最明显
    float tint = tintShift / 1000.0;
    float midtoneMask = clamp(1.0 - abs(lum - 0.5) * 1.5, 0.0, 1.0);
    c.g = clamp(c.g + tint * -0.008 * midtoneMask, 0.0, 1.0);
    return c;
}

// Kodak Portra 肤色保护
vec3 fqsSkinToneGuard(vec3 c) {
    float skinMask = 0.0;
    if (c.r > c.g && c.g > c.b && (c.r - c.b) > 0.08) {
        skinMask = clamp((c.r - c.b - 0.08) * 3.0, 0.0, 1.0);
    }
    c.r = clamp(c.r + skinMask * 0.012, 0.0, 1.0);
    c.g = clamp(c.g + skinMask * 0.004, 0.0, 1.0);
    return c;
}

float fqsVignette(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── 主函数 ──────────────────────────────────────────────────────────

void main() {
    vec2 uv = vTexCoord;

    // ── Pass 1: 色差 (Chromatic Aberration) ─────────────────────────
    vec3 color;
    if (uChromaticAberration > 0.0) {
        float ca = uChromaticAberration * 0.01;
        float r = texture(uCameraTexture, uv + vec2(ca,  0.0)).r;
        float g = texture(uCameraTexture, uv).g;
        float b = texture(uCameraTexture, uv - vec2(ca,  0.0)).b;
        color = vec3(r, g, b);
    } else {
        color = texture(uCameraTexture, uv).rgb;
    }

    // ── Pass 2: Tone Curve（胶片曲线）────────────────────────────────
    color.r = fqsToneCurve(color.r);
    color.g = fqsToneCurve(color.g);
    color.b = fqsToneCurve(color.b);

    // ── Pass 3: RGB Channel Shift（Fuji Superia 色偏）─────────────────
    // R*0.96, G*1.05, B*1.02（通过 colorBias 参数控制）
    color.r = clamp(color.r * (1.0 + uColorBiasR), 0.0, 1.0);
    color.g = clamp(color.g * (1.0 + uColorBiasG), 0.0, 1.0);
    color.b = clamp(color.b * (1.0 + uColorBiasB), 0.0, 1.0);

    // ── Pass 4: 饱和度（1.05）────────────────────────────────────────
    color = fqsSaturation(color, uSaturation);

    // ── Pass 5: 对比度（0.92）────────────────────────────────────────
    color = fqsContrast(color, uContrast);

    // ── Pass 6: 色温 + Tint ───────────────────────────────────────────
    color = fqsTemperatureTint(color, uTemperatureShift, uTintShift);

    // ── Pass 7: Kodak Portra 肤色保护 ────────────────────────────────
    color = fqsSkinToneGuard(color);

    // ── Pass 8: Highlight Halation（高光发光）────────────────────────
    float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    if (uHalationAmount > 0.0 && lum > 0.75) {
        float halationMask = clamp((lum - 0.75) / 0.25, 0.0, 1.0);
        halationMask = halationMask * halationMask;
        // 高光发红（胶片 Halation 特征）
        vec3 halationColor = vec3(
            color.r * 1.15,
            color.g * 0.95,
            color.b * 0.80
        );
        color = mix(color, halationColor, halationMask * uHalationAmount);
    }

    // ── Pass 9: Bloom（柔光）─────────────────────────────────────────
    if (uBloomAmount > 0.0 && lum > 0.80) {
        float bloom = clamp((lum - 0.80) * uBloomAmount * 2.0, 0.0, 0.3);
        color = clamp(color + vec3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }

    // ── Pass 10: 胶片颗粒（Film Grain，grain_color=true）────────────
    // grain_intensity=0.28, grain_size=1.8
    if (uGrainAmount > 0.0) {
        float timeSeed = floor(uTime * 24.0) / 24.0;  // 锁定 24fps

        // 亮度颗粒（主颗粒）
        float grainLuma = fqsRandom(uv * uGrainSize, timeSeed) - 0.5;

        // 彩色颗粒（FQS grain_color=true）
        float grainR = fqsRandom(uv * uGrainSize, timeSeed + 0.1) - 0.5;
        float grainG = fqsRandom(uv * uGrainSize, timeSeed + 0.2) - 0.5;
        float grainB = fqsRandom(uv * uGrainSize, timeSeed + 0.3) - 0.5;

        // 颗粒强度随亮度变化：中间调最明显
        float grainLumValue = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float grainMask = clamp(1.0 - abs(grainLumValue - 0.45) * 1.2, 0.3, 1.0);

        // 混合：60% 亮度颗粒 + 40% 彩色颗粒
        vec3 totalGrain = mix(
            vec3(grainLuma),
            vec3(grainR, grainG, grainB) * 0.3,
            0.4
        );
        color = clamp(color + totalGrain * uGrainAmount * 0.22 * grainMask, 0.0, 1.0);
    }

    // ── Pass 11: 亮度噪声 + 色度噪声（胶片扫描噪声）────────────────
    if (uLuminanceNoise > 0.0) {
        float noise = fqsRandom(uv, uTime * 0.5) - 0.5;
        float darkMask = 1.0 - clamp(lum * 1.5, 0.0, 1.0);
        color = clamp(color + noise * uLuminanceNoise * 0.15 * darkMask, 0.0, 1.0);
    }
    if (uChromaNoise > 0.0) {
        vec3 chromaNoise = vec3(
            fqsRandom(uv, uTime * 0.3 + 10.0) - 0.5,
            fqsRandom(uv, uTime * 0.3 + 20.0) - 0.5,
            fqsRandom(uv, uTime * 0.3 + 30.0) - 0.5
        );
        float darkMask = 1.0 - clamp(lum * 2.0, 0.0, 1.0);
        color = clamp(color + chromaNoise * uChromaNoise * 0.10 * darkMask, 0.0, 1.0);
    }

    // ── Pass 12: 暗角（Vignette）─────────────────────────────────────
    if (uVignetteAmount > 0.0) {
        float vignette = fqsVignette(uv, uVignetteAmount);
        color *= vignette;
    }

    fragColor = vec4(color, 1.0);
}
"""

    /**
     * FQS 默认参数值（对应 fqs.json 的 defaultLook）
     * 在 CameraGLRenderer.updateParams() 中通过 key 传入
     */
    val DEFAULT_PARAMS = mapOf(
        "contrast"           to 0.92f,
        "saturation"         to 1.05f,
        "temperatureShift"   to -40.0f,
        "chromaticAberration" to 0.004f,
        "vignette"           to 0.15f,
        "grain"              to 0.28f,
        // FQS 专有参数
        "colorBiasR"         to -0.04f,
        "colorBiasG"         to  0.05f,
        "colorBiasB"         to  0.02f,
        "tintShift"          to -18.0f,
        "halationAmount"     to  0.15f,
        "bloomAmount"        to  0.10f,
        "grainSize"          to  1.8f,
        "luminanceNoise"     to  0.08f,
        "chromaNoise"        to  0.05f
    )
}
