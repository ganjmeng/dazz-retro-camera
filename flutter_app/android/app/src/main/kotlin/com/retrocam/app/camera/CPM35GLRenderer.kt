package com.retrocam.app.camera

/**
 * CPM35GLRenderer — Kodak Gold 200 / ColorPlus 200 GLSL Shader
 *
 * 这是 CPM35 相机模式的专用 OpenGL ES 3.0 渲染器。
 * 架构与 FQSGLRenderer 完全一致，但使用 Kodak 暖色科学替代 Fuji 绿调。
 *
 * CPM35 Pipeline 顺序：
 *   Camera Frame
 *   → Chromatic Aberration（色差，0.15，比 FQS 克制）
 *   → Tone Curve（Kodak 胶片曲线）
 *   → RGB Channel Shift（R+4%, G+2%, B-4%，暖色，与 FQS 方向相反）
 *   → Saturation（饱和度 1.08）
 *   → Contrast（对比度 1.02，比 FQS 的 0.92 略高，更通透）
 *   → Temperature + Tint（色温 +120K 暖色，Tint +4 轻微品红）
 *   → Highlight Warmth（Kodak 式暖高光，非 FQS 的发红 Halation）
 *   → Halation（克制的高光溢出，0.06）
 *   → Bloom（轻柔光，0.05）
 *   → Film Grain（轻颗粒，grain_intensity=0.16, grain_size=1.6）
 *   → Luminance Noise + Chroma Noise（轻扫描噪声）
 *   → Vignette（暗角 0.10，比 FQS 轻）
 *   → Output
 *
 * 与 FQS 的关键差异：
 *   FQS:   R-4%, G+5%, B+2% → 偏冷绿（Fuji Superia 风格）
 *   CPM35: R+4%, G+2%, B-4% → 偏暖（Kodak Gold 风格）
 *   FQS:   grain=0.28（明显颗粒）  CPM35: grain=0.16（轻颗粒）
 *   FQS:   halation=0.15（高光发红）  CPM35: halation=0.06（暖橙色，克制）
 */
object CPM35ShaderSource {

    /**
     * CPM35 Fragment Shader（OpenGL ES 3.0）
     *
     * 新增 Uniform（相比 CameraGLRenderer 的基础 Shader）：
     *   uColorBiasR/G/B      — RGB 通道偏移（Kodak 暖色偏移）
     *   uHighlightWarmAmount — 高光暖推强度（Kodak 式暖高光）
     *   uHalationAmount      — 高光溢出强度
     *   uBloomAmount         — 柔光强度
     *   uGrainSize           — 颗粒大小
     *   uTintShift           — Tint 偏移（轻微品红）
     *   uLuminanceNoise      — 亮度噪声强度
     *   uChromaNoise         — 色度噪声强度
     */
    const val FRAGMENT_SHADER = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;

in  vec2 vTexCoord;
out vec4 fragColor;

uniform samplerExternalOES uCameraTexture;

// ── 基础参数（与 CameraGLRenderer / FQSGLRenderer 兼容）───────────
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift;
uniform float uChromaticAberration;
uniform float uVignetteAmount;
uniform float uGrainAmount;
uniform float uTime;
uniform vec2  uTexelSize;

// ── CPM35 专有参数 ──────────────────────────────────────────────────
uniform float uColorBiasR;           // RGB Channel Shift R（推荐 +0.04，暖红）
uniform float uColorBiasG;           // RGB Channel Shift G（推荐 +0.02）
uniform float uColorBiasB;           // RGB Channel Shift B（推荐 -0.04，压蓝）
uniform float uTintShift;            // Tint 偏移（推荐 +4，轻微品红）
uniform float uHighlightWarmAmount;  // 高光暖推（推荐 0.06）
uniform float uHalationAmount;       // 高光溢出（推荐 0.06）
uniform float uBloomAmount;          // 柔光（推荐 0.05）
uniform float uGrainSize;            // 颗粒大小（推荐 1.6）
uniform float uLuminanceNoise;       // 亮度噪声（推荐 0.05）
uniform float uChromaNoise;          // 色度噪声（推荐 0.03）

// ── 工具函数 ────────────────────────────────────────────────────────

float cpm35Random(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

// CPM35 Tone Curve（Kodak Gold 胶片曲线）
// 控制点（归一化）：
//   (0.000, 0.000) (0.125, 0.102) (0.251, 0.235)
//   (0.502, 0.494) (0.753, 0.816) (1.000, 0.988)
// 特点：阴影轻压（比 FQS 更自然），高光柔和 roll-off（Kodak 特征）
float cpm35ToneCurve(float v) {
    v = clamp(v, 0.0, 1.0);
    float t;

    if (v <= 0.12549) {
        t = v / 0.12549;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.0, 0.10196, t);
    } else if (v <= 0.25098) {
        t = (v - 0.12549) / 0.12549;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.10196, 0.23529, t);
    } else if (v <= 0.50196) {
        t = (v - 0.25098) / 0.25098;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.23529, 0.49412, t);
    } else if (v <= 0.75294) {
        t = (v - 0.50196) / 0.25098;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.49412, 0.81569, t);
    } else {
        t = (v - 0.75294) / 0.24706;
        t = t * t * (3.0 - 2.0 * t);
        return mix(0.81569, 0.98824, t);
    }
}

vec3 cpm35Contrast(vec3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

vec3 cpm35Saturation(vec3 c, float sat) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(lum), c, sat), 0.0, 1.0);
}

// 色温 + Tint（Kodak 暖色版本）
// 正 tempShift = 暖（R增，B减），与 FQS 的负值偏冷相反
vec3 cpm35TemperatureTint(vec3 c, float tempShift, float tintShift) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float strength = lum * 0.8 + 0.2;
    float ts = tempShift / 1000.0;
    // 正温度 = 暖：R增，B减
    c.r = clamp(c.r + ts * 0.018 * strength, 0.0, 1.0);
    c.b = clamp(c.b - ts * 0.022 * strength, 0.0, 1.0);
    // Tint：正值偏品红（Kodak 特征）
    float tint = tintShift / 1000.0;
    float midtoneMask = clamp(1.0 - abs(lum - 0.5) * 1.5, 0.0, 1.0);
    c.r = clamp(c.r + tint * 0.006 * midtoneMask, 0.0, 1.0);
    c.b = clamp(c.b + tint * 0.004 * midtoneMask, 0.0, 1.0);
    return c;
}

// Kodak Gold 暖高光（高光区整体暖推，区别于 FQS 的发红 Halation）
vec3 cpm35HighlightWarmth(vec3 c, float amount) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    if (lum > 0.55) {
        float warmMask = clamp((lum - 0.55) / 0.45, 0.0, 1.0);
        warmMask = warmMask * warmMask;
        vec3 warmColor = vec3(
            c.r * (1.0 + amount * 0.04),
            c.g * (1.0 + amount * 0.016),
            c.b * (1.0 - amount * 0.05)
        );
        c = mix(c, warmColor, warmMask);
    }
    return clamp(c, 0.0, 1.0);
}

float cpm35Vignette(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── 主函数 ──────────────────────────────────────────────────────────

void main() {
    vec2 uv = vTexCoord;

    // ── Pass 1: 色差 (Chromatic Aberration, 0.15) ────────────────────
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

    // ── Pass 2: Tone Curve（Kodak 胶片曲线）──────────────────────────
    color.r = cpm35ToneCurve(color.r);
    color.g = cpm35ToneCurve(color.g);
    color.b = cpm35ToneCurve(color.b);

    // ── Pass 3: RGB Channel Shift（Kodak Gold 暖色偏移）──────────────
    // R×1.04, G×1.02, B×0.96（与 FQS 的 R×0.96, G×1.05, B×1.02 相反）
    color.r = clamp(color.r * (1.0 + uColorBiasR), 0.0, 1.0);
    color.g = clamp(color.g * (1.0 + uColorBiasG), 0.0, 1.0);
    color.b = clamp(color.b * (1.0 + uColorBiasB), 0.0, 1.0);

    // ── Pass 4: 饱和度（1.08）────────────────────────────────────────
    color = cpm35Saturation(color, uSaturation);

    // ── Pass 5: 对比度（1.02，Kodak 更通透）─────────────────────────
    color = cpm35Contrast(color, uContrast);

    // ── Pass 6: 色温 + Tint（+120K 暖色，+4 tint）───────────────────
    color = cpm35TemperatureTint(color, uTemperatureShift, uTintShift);

    // ── Pass 7: Kodak 暖高光（高光区整体暖推）───────────────────────
    color = cpm35HighlightWarmth(color, uHighlightWarmAmount);

    // ── Pass 8: Halation（克制，0.06，暖橙色）───────────────────────
    float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    if (uHalationAmount > 0.0 && lum > 0.80) {
        float halationMask = clamp((lum - 0.80) / 0.20, 0.0, 1.0);
        halationMask = halationMask * halationMask;
        // CPM35 Halation：暖橙色（区别于 FQS 的暖红）
        vec3 halationColor = vec3(
            color.r * 1.08,
            color.g * 1.02,
            color.b * 0.90
        );
        color = mix(color, halationColor, halationMask * uHalationAmount * 0.5);
    }

    // ── Pass 9: Bloom（轻柔光，0.05）─────────────────────────────────
    if (uBloomAmount > 0.0 && lum > 0.82) {
        float bloom = clamp((lum - 0.82) * uBloomAmount * 2.0, 0.0, 0.2);
        // CPM35 Bloom：暖色调（R略多于B）
        color = clamp(color + vec3(bloom * 0.9, bloom * 0.75, bloom * 0.55), 0.0, 1.0);
    }

    // ── Pass 10: 胶片颗粒（轻颗粒，grain_intensity=0.16, grain_size=1.6）─
    if (uGrainAmount > 0.0) {
        float timeSeed = floor(uTime * 24.0) / 24.0;  // 锁定 24fps

        // 亮度颗粒（主颗粒）
        float grainLuma = cpm35Random(uv * uGrainSize, timeSeed) - 0.5;

        // 彩色颗粒（比 FQS 比例更低，70% 亮度 + 30% 彩色）
        float grainR = cpm35Random(uv * uGrainSize, timeSeed + 0.1) - 0.5;
        float grainG = cpm35Random(uv * uGrainSize, timeSeed + 0.2) - 0.5;
        float grainB = cpm35Random(uv * uGrainSize, timeSeed + 0.3) - 0.5;

        // 颗粒强度随亮度变化：中间调最明显
        float grainLumValue = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float grainMask = clamp(1.0 - abs(grainLumValue - 0.45) * 1.2, 0.3, 1.0);

        // 混合：70% 亮度颗粒 + 30% 彩色颗粒（比 FQS 更偏向亮度颗粒）
        vec3 totalGrain = mix(
            vec3(grainLuma),
            vec3(grainR, grainG, grainB) * 0.25,
            0.3
        );
        color = clamp(color + totalGrain * uGrainAmount * 0.22 * grainMask, 0.0, 1.0);
    }

    // ── Pass 11: 亮度噪声 + 色度噪声（轻扫描噪声）──────────────────
    if (uLuminanceNoise > 0.0) {
        float noise = cpm35Random(uv, uTime * 0.5) - 0.5;
        float darkMask = 1.0 - clamp(lum * 1.5, 0.0, 1.0);
        color = clamp(color + noise * uLuminanceNoise * 0.15 * darkMask, 0.0, 1.0);
    }
    if (uChromaNoise > 0.0) {
        vec3 chromaNoise = vec3(
            cpm35Random(uv, uTime * 0.3 + 10.0) - 0.5,
            cpm35Random(uv, uTime * 0.3 + 20.0) - 0.5,
            cpm35Random(uv, uTime * 0.3 + 30.0) - 0.5
        );
        float darkMask = 1.0 - clamp(lum * 2.0, 0.0, 1.0);
        color = clamp(color + chromaNoise * uChromaNoise * 0.10 * darkMask, 0.0, 1.0);
    }

    // ── Pass 12: 暗角（Vignette，0.10，比 FQS 的 0.15 更轻）────────
    if (uVignetteAmount > 0.0) {
        float vignette = cpm35Vignette(uv, uVignetteAmount);
        color *= vignette;
    }

    fragColor = vec4(color, 1.0);
}
"""

    /**
     * CPM35 默认参数值（对应 cpm35.json 的 defaultLook）
     * 在 CameraGLRenderer.updateParams() 中通过 key 传入
     */
    val DEFAULT_PARAMS = mapOf(
        // 基础参数（与 CameraGLRenderer 兼容的 key）
        "contrast"              to 1.02f,
        "saturation"            to 1.08f,
        "temperatureShift"      to 80.0f,    // 正值 = 偏暖，老式胶片机暖调（降低强度，120 过强）
        "chromaticAberration"   to 0.0015f,  // 0.15 映射到 0.0015
        "vignette"              to 0.10f,
        "grain"                 to 0.16f,    // 比 FQS 的 0.28 轻
        // CPM35 专有参数
        "colorBiasR"            to  0.04f,   // 暖红（FQS 是 -0.04）
        "colorBiasG"            to  0.02f,   // 轻微（FQS 是 +0.05）
        "colorBiasB"            to -0.04f,   // 压蓝（FQS 是 +0.02）
        "tintShift"             to  4.0f,    // 轻微品红（FQS 是 -18 偏绿）
        "highlightWarmAmount"   to  0.06f,   // Kodak 暖高光
        "halationAmount"        to  0.06f,   // 克制（FQS 是 0.15）
        "bloomAmount"           to  0.05f,   // 轻柔光（FQS 是 0.10）
        "grainSize"             to  1.6f,    // 细颗粒（FQS 是 1.8）
        "luminanceNoise"        to  0.05f,   // 轻噪声（FQS 是 0.08）
        "chromaNoise"           to  0.03f    // 轻噪声（FQS 是 0.05）
    )
}
