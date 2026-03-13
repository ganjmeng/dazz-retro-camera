#extension GL_OES_EGL_image_external : require
precision mediump float;

// 相机输入纹理（来自 CameraX 的 SurfaceTexture）
uniform samplerExternalOES uCameraTexture;
// LUT 纹理（用于色彩重映射）
uniform sampler2D uLutTexture;
// 胶片颗粒纹理
uniform sampler2D uGrainTexture;

// CCD 效果参数 Uniforms
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift; // 负数偏冷
uniform float uGrainAmount;
uniform float uNoiseAmount;
uniform float uVignetteAmount;
uniform float uChromaticAberration;
uniform float uBloomAmount;
uniform float uTime; // 用于动态噪点的时间种子

varying vec2 vTexCoord;

// ============================================================
// 工具函数
// ============================================================

// 计算暗角强度
float vignetteEffect(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return 1.0 - dot(d, d) * amount * 2.5;
}

// 简单的伪随机噪点生成
float random(vec2 st, float seed) {
    return fract(sin(dot(st + seed, vec2(12.9898, 78.233))) * 43758.5453);
}

// 色温偏移（简化版）
vec3 applyTemperatureShift(vec3 color, float shift) {
    float normalizedShift = shift / 1000.0;
    color.r = clamp(color.r - normalizedShift * 0.3, 0.0, 1.0);
    color.b = clamp(color.b + normalizedShift * 0.3, 0.0, 1.0);
    return color;
}

// 对比度调整
vec3 applyContrast(vec3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

// 饱和度调整
vec3 applySaturation(vec3 color, float saturation) {
    float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
    return mix(vec3(luminance), color, saturation);
}

// ============================================================
// 主函数
// ============================================================

void main() {
    vec2 uv = vTexCoord;

    // === Pass 1: 色差 (Chromatic Aberration) ===
    float ca = uChromaticAberration;
    float r = texture2D(uCameraTexture, uv + vec2(ca, 0.0)).r;
    float g = texture2D(uCameraTexture, uv).g;
    float b = texture2D(uCameraTexture, uv - vec2(ca, 0.0)).b;
    vec3 color = vec3(r, g, b);

    // === Pass 2: 基础色彩调整 ===
    color = applyTemperatureShift(color, uTemperatureShift);
    color = applyContrast(color, uContrast);
    color = applySaturation(color, uSaturation);

    // === Pass 3: 高光溢出 (Bloom) ===
    float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
    if (luminance > 0.8 && uBloomAmount > 0.0) {
        float bloom = (luminance - 0.8) * uBloomAmount * 2.0;
        color = clamp(color + vec3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }

    // === Pass 4: 胶片颗粒 (Grain) ===
    if (uGrainAmount > 0.0) {
        vec3 grain = texture2D(uGrainTexture, uv * 2.0).rgb;
        color = clamp(color + (grain - 0.5) * uGrainAmount * 0.3, 0.0, 1.0);
    }

    // === Pass 5: 动态数字噪点 (Noise) ===
    if (uNoiseAmount > 0.0) {
        float noise = random(uv, uTime) - 0.5;
        float darkMask = 1.0 - luminance;
        color = clamp(color + noise * uNoiseAmount * 0.2 * darkMask, 0.0, 1.0);
    }

    // === Pass 6: 暗角 (Vignette) ===
    float vignette = vignetteEffect(uv, uVignetteAmount);
    color *= vignette;

    gl_FragColor = vec4(color, 1.0);
}
