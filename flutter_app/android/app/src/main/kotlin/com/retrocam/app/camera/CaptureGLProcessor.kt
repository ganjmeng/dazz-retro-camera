package com.retrocam.app.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * CaptureGLProcessor — 基于 OpenGL ES 3.0 离屏渲染的 GPU 成片处理器
 *
 * 替代原 RenderScript（AGP 8.x 已移除 RenderScript 支持）。
 * 使用 EGL PBuffer Surface 创建离屏 GL 上下文，将 JPEG 图像上传为 GL 纹理，
 * 通过 fragment shader 执行完整成片管线，再用 glReadPixels 回读结果。
 *
 * 管线顺序（与 capture_pipeline.rs 和 iOS CapturePipeline.metal 完全一致）：
 *   Pass 1:  色差（Chromatic Aberration）
 *   Pass 2:  色温 + Tint
 *   Pass 3:  黑场/白场
 *   Pass 4:  高光/阴影压缩
 *   Pass 5:  对比度
 *   Pass 6:  Clarity（中间调微对比度）
 *   Pass 7:  饱和度 + Vibrance
 *   Pass 8:  RGB 通道偏移（Color Bias）
 *   Pass 9:  Bloom（高光光晕）
 *   Pass 10: Halation（高光辉光）
 *   Pass 11: Highlight Rolloff（高光柔和滚落，成片专属）
 *   Pass 12: Center Gain（中心增亮，成片专属）
 *   Pass 13: Skin Protection（肤色保护，成片专属）
 *   Pass 14: Edge Falloff + Corner Warm Shift（成片专属）
 *   Pass 15: Chemical Irregularity（化学不规则感，成片专属）
 *   Pass 16: Paper Texture（相纸纹理，成片专属）
 *   Pass 17: Film Grain（胶片颗粒）
 *   Pass 18: Digital Noise（数字噪点）
 *   Pass 19: Vignette（暗角）
 */
class CaptureGLProcessor(private val context: Context) {

    companion object {
        private const val TAG = "CaptureGLProcessor"

        // ── 顶点着色器 ──────────────────────────────────────────────────────
        private const val VERTEX_SHADER = """#version 300 es
in vec4 aPosition;
in vec2 aTexCoord;
out vec2 vTexCoord;
void main() {
    gl_Position = aPosition;
    vTexCoord = aTexCoord;
}"""

        // ── 片段着色器（成片完整管线）──────────────────────────────────────
        private const val FRAGMENT_SHADER = """#version 300 es
precision highp float;
in  vec2 vTexCoord;
out vec4 fragColor;

uniform sampler2D uInputTexture;
uniform vec2  uTexelSize;       // 1/width, 1/height

// ── 基础色彩参数 ────────────────────────────────────────────────────────
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift;
uniform float uTintShift;

// ── Lightroom 风格曲线参数 ────────────────────────────────────────────
uniform float uHighlights;
uniform float uShadows;
uniform float uWhites;
uniform float uBlacks;
uniform float uClarity;
uniform float uVibrance;

// ── RGB 通道偏移 ──────────────────────────────────────────────────────
uniform float uColorBiasR;
uniform float uColorBiasG;
uniform float uColorBiasB;

// ── 胶片效果参数 ──────────────────────────────────────────────────────
uniform float uGrainAmount;
uniform float uNoiseAmount;
uniform float uVignetteAmount;
uniform float uLensVignette;
uniform float uChromaticAberration;
uniform float uBloomAmount;
uniform float uHalationAmount;
uniform float uTime;

// ── 成片专属参数 ──────────────────────────────────────────────────────
uniform float uHighlightRolloff;
uniform float uHighlightRolloff2;   // 高光柔和滚落 2（FXN-R 专属）
uniform float uToneCurveStrength;   // Tone Curve 强度（FXN-R 专属）
uniform float uPaperTexture;
uniform float uEdgeFalloff;
uniform float uExposureVariation;
uniform float uCornerWarmShift;
uniform float uCenterGain;
uniform float uDevelopmentSoftness;
uniform float uChemicalIrregularity;
uniform float uSkinHueProtect;
uniform float uSkinSatProtect;
uniform float uSkinLumaSoften;
uniform float uSkinRedLimit;
uniform float uGrainSize;            // 颗粒大小
uniform float uLuminanceNoise;       // 亮度噪声
uniform float uChromaNoise;           // 色度噪声
// ── Fade / Split Toning / Light Leak ──
uniform float uFadeAmount;
uniform vec3  uShadowTint;
uniform vec3  uHighlightTint;
uniform float uSplitToneBalance;
uniform float uLightLeakAmount;
uniform float uLightLeakSeed;
uniform float uExposureOffset;        // 用户曝光补偿（-2.0~+2.0）
uniform float uFisheyeMode;           // 1.0=圆形鱼眼模式, 0.0=普通模式
uniform float uAspectRatio;           // 宽/高，用于鱼眼圆形不变形
// ── 工具函数 ──────────────────────────────────────────────────────────────
float luminance(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// 伪随机噪点
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
// ── 圆形鱼眼 UV 重映射（等距投影，与 CameraGLRenderer 完全一致）
// 返回 vec2(-1) 表示圆形以外区域
vec2 fisheyeUV(vec2 uv, float aspect) {
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r = length(p);
    if (r > 1.0) return vec2(-1.0);
    float theta = r * 1.5707963; // pi/2
    float phi = atan(p.y, p.x);
    float sinTheta = sin(theta);
    vec2 texCoord = vec2(sinTheta * cos(phi), sinTheta * sin(phi));
    return texCoord * 0.5 + 0.5;
}
// ── Pass 1: 色差 ──────────────────────────────────────────────────────────────
vec3 applyChromaticAberration(sampler2D tex, vec2 uv, float amount) {
    if (amount < 0.001) return texture(tex, uv).rgb;
    vec2 offset = (uv - 0.5) * amount * 0.02;
    float r = texture(tex, uv + offset).r;
    float g = texture(tex, uv).g;
    float b = texture(tex, uv - offset).b;
    return vec3(r, g, b);
}

// ── Pass 2: 色温 ──────────────────────────────────────────────────────
vec3 applyTemperature(vec3 c, float shift) {
    // shift 范围 -200~+200，/1000 后约 ±0.2，与预览 Shader 对齐
    float s = shift / 1000.0;
    c.r = clamp(c.r + s * 0.3, 0.0, 1.0);
    c.b = clamp(c.b - s * 0.3, 0.0, 1.0);
    return c;
}

vec3 applyTint(vec3 c, float shift) {
    // shift 范围 -200~+200，/1000 后约 ±0.2，与预览 Shader 对齐
    float s = shift / 1000.0;
    c.g = clamp(c.g + s * 0.2, 0.0, 1.0);
    return c;
}

// ── Pass 3: 黑场/白场 ─────────────────────────────────────────────────
vec3 applyBlacksWhites(vec3 c, float blacks, float whites) {
    float b = blacks / 200.0;
    float w = whites / 200.0;
    c = c * (1.0 + w - b) + b;
    return clamp(c, 0.0, 1.0);
}

// ── Pass 4: 高光/阴影 ─────────────────────────────────────────────────
vec3 applyHighlightsShadows(vec3 c, float highlights, float shadows) {
    float lum = luminance(c);
    float h = highlights / 200.0;
    float s = shadows / 200.0;
    float highlightMask = smoothstep(0.5, 1.0, lum);
    float shadowMask    = 1.0 - smoothstep(0.0, 0.5, lum);
    c = c + c * h * highlightMask - c * h * highlightMask * highlightMask;
    c = c + (1.0 - c) * s * shadowMask;
    return clamp(c, 0.0, 1.0);
}

// ── Pass 5: 对比度 ────────────────────────────────────────────────────
vec3 applyContrast(vec3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

// ── Pass 6: Clarity ───────────────────────────────────────────────────
vec3 applyClarity(vec3 c, float clarity, sampler2D tex, vec2 uv) {
    if (abs(clarity) < 0.5) return c;
    // 简单的局部对比度增强（近似 Clarity）
    vec3 blurred = vec3(0.0);
    float w = uTexelSize.x * 3.0;
    float h = uTexelSize.y * 3.0;
    blurred += texture(tex, uv + vec2(-w, -h)).rgb * 0.0625;
    blurred += texture(tex, uv + vec2( 0, -h)).rgb * 0.125;
    blurred += texture(tex, uv + vec2( w, -h)).rgb * 0.0625;
    blurred += texture(tex, uv + vec2(-w,  0)).rgb * 0.125;
    blurred += texture(tex, uv + vec2( 0,  0)).rgb * 0.25;
    blurred += texture(tex, uv + vec2( w,  0)).rgb * 0.125;
    blurred += texture(tex, uv + vec2(-w,  h)).rgb * 0.0625;
    blurred += texture(tex, uv + vec2( 0,  h)).rgb * 0.125;
    blurred += texture(tex, uv + vec2( w,  h)).rgb * 0.0625;
    float midMask = 1.0 - abs(luminance(c) * 2.0 - 1.0);
    vec3 detail = c - blurred;
    return clamp(c + detail * clarity * 0.3 * midMask, 0.0, 1.0);
}

// ── Pass 7: 饱和度 + Vibrance ─────────────────────────────────────────
vec3 applySaturation(vec3 c, float sat) {
    float lum = luminance(c);
    return clamp(mix(vec3(lum), c, sat), 0.0, 1.0);
}

vec3 applyVibrance(vec3 c, float vibrance) {
    if (abs(vibrance) < 0.5) return c;
    float v = vibrance / 100.0;
    float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    float mask = 1.0 - sat;
    float lum = luminance(c);
    return clamp(mix(vec3(lum), c, 1.0 + v * mask), 0.0, 1.0);
}

// ── Pass 8: RGB 通道偏移 ──────────────────────────────────────────────
vec3 applyColorBias(vec3 c, float r, float g, float b) {
    // colorBias 值已是归一化的小数（如 -0.030, +0.048），直接加，与预览 Shader 对齐
    return clamp(c + vec3(r, g, b), 0.0, 1.0);
}

// ── Pass 9: Bloom（空间扩散光晕）───────────────────────────────────────────
vec3 applyBloom(vec3 c, float amount, vec2 uv) {
    if (amount < 0.001) return c;
    float bloomRadius = amount * 12.0;
    vec3 bloomColor = vec3(0.0);
    float totalWeight = 0.0;
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            vec2 offset = vec2(float(i), float(j)) * uTexelSize * bloomRadius;
            vec3 sample_c = texture(uInputTexture, uv + offset).rgb;
            float sLum = luminance(sample_c);
            float highlight = clamp((sLum - 0.7) / 0.3, 0.0, 1.0);
            float w = (i == 0 && j == 0) ? 4.0 : (abs(i) + abs(j) == 1 ? 2.0 : 1.0);
            bloomColor += sample_c * highlight * w;
            totalWeight += w;
        }
    }
    bloomColor /= totalWeight;
    bloomColor *= vec3(1.0, 0.9, 0.7);
    c = clamp(c + bloomColor * amount * 1.5, 0.0, 1.0);
    return c;
}
// ── Pass 10: Halation（红橙色胶片辉光，空间扩散）───────────────────────
vec3 applyHalation(vec3 c, float amount, vec2 uv) {
    if (amount < 0.001) return c;
    float haloRadius = amount * 18.0;
    vec3 haloColor = vec3(0.0);
    float totalWeight = 0.0;
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            if (abs(i) + abs(j) > 3) continue;
            vec2 offset = vec2(float(i), float(j)) * uTexelSize * haloRadius;
            vec3 sample_c = texture(uInputTexture, uv + offset).rgb;
            float sLum = luminance(sample_c);
            float highlight = clamp((sLum - 0.6) / 0.4, 0.0, 1.0);
            float dist = float(abs(i) + abs(j));
            float w = 1.0 / (1.0 + dist);
            haloColor += sample_c * highlight * w;
            totalWeight += w;
        }
    }
    haloColor /= totalWeight;
    float haloLum = luminance(haloColor);
    c.r = clamp(c.r + haloLum * amount * 1.2, 0.0, 1.0);
    c.g = clamp(c.g + haloLum * amount * 0.35, 0.0, 1.0);
    c.b = clamp(c.b + haloLum * amount * 0.05, 0.0, 1.0);
    return c;
}

// ── Pass 11: Highlight Rolloff ────────────────────────────────────
vec3 applyHighlightRolloff(vec3 c, float rolloff) {
    if (rolloff < 0.001) return c;
    float lum = luminance(c);
    float mask = smoothstep(0.7, 1.0, lum);
    float compress = 1.0 - mask * rolloff * 0.3;
    return clamp(c * compress + vec3(mask * rolloff * 0.05), 0.0, 1.0);
}

// ── Pass 11b: Highlight Rolloff 2（FXN-R 专属，二次压缩）────────────────────
vec3 applyCaptureHighlightRolloff2(vec3 c, float rolloff) {
    if (rolloff < 0.001) return c;
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.3;
    return clamp(c * compress, 0.0, 1.0);
}

// ── Pass 11c: Tone Curve（FXN-R 专属，分段线性插値）────────────────────
float captureApplyToneCurve(float x) {
    float[10] inp = float[10](0.0, 0.0627, 0.1255, 0.2510, 0.3765, 0.5020, 0.6275, 0.7529, 0.8784, 1.0);
    float[10] outVals = float[10](0.0, 0.0392, 0.0941, 0.2235, 0.3608, 0.4863, 0.6588, 0.8235, 0.9333, 0.9804);
    for (int i = 0; i < 9; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outVals[i], outVals[i + 1], t);
        }
    }
    return outVals[9];
}

// ── Pass 14b: Development Softness（显影柔化）──────────────────────────
vec3 applyDevelopmentSoften(vec3 c, vec2 uv, float softness) {
    if (softness < 0.001) return c;
    vec3 blurred =
        texture(uInputTexture, uv + vec2(-uTexelSize.x, 0.0)).rgb * 0.25 +
        texture(uInputTexture, uv + vec2( uTexelSize.x, 0.0)).rgb * 0.25 +
        texture(uInputTexture, uv + vec2(0.0, -uTexelSize.y)).rgb * 0.25 +
        texture(uInputTexture, uv + vec2(0.0,  uTexelSize.y)).rgb * 0.25;
    return mix(c, blurred, softness * 0.5);
}

// ── Pass 12: Center Gain ────────────────────────────────────────────
vec3 applyCenterGain(vec3 c, vec2 uv, float gain) {
    if (gain < 0.001) return c;
    float dist = length(uv - 0.5) * 2.0;
    float mask = 1.0 - smoothstep(0.0, 1.0, dist);
    return clamp(c * (1.0 + gain * mask), 0.0, 1.0);
}

// ── Pass 13: 肤色保护 ─────────────────────────────────────────────────
vec3 applySkinProtect(vec3 c, float protect, float satProt, float lumSoften, float redLimit) {
    if (protect < 0.01) return c;
    vec3 hsv = rgb2hsv(c);
    float hue = hsv.x * 360.0;
    float skinMask = 0.0;
    if (hue > 0.0 && hue < 50.0) {
        skinMask = smoothstep(0.0, 25.0, hue) * (1.0 - smoothstep(25.0, 50.0, hue));
        skinMask *= smoothstep(0.1, 0.4, hsv.y) * smoothstep(0.85, 0.3, hsv.y);
        skinMask *= protect;
    }
    if (skinMask < 0.01) return c;
    float lum = luminance(c);
    vec3 desat = vec3(lum);
    vec3 result = c;
    result = mix(result, desat, skinMask * (1.0 - satProt));
    result = clamp(result + vec3(lum * skinMask * lumSoften * 0.8), 0.0, 1.0);
    result.r = clamp(result.r, 0.0, redLimit);
    return mix(c, result, skinMask);
}

// ── Pass 14: Edge Falloff + Corner Warm Shift ─────────────────────────
vec3 applyEdgeFalloff(vec3 c, vec2 uv, float falloff) {
    if (falloff < 0.001) return c;
    float dist = length(uv - 0.5) * 2.0;
    float mask = smoothstep(0.5, 1.5, dist);
    return clamp(c * (1.0 - mask * falloff * 0.5), 0.0, 1.0);
}

vec3 applyCornerWarm(vec3 c, vec2 uv, float shift) {
    if (abs(shift) < 0.001) return c;
    float dist = length(uv - 0.5) * 2.0;
    float mask = smoothstep(0.7, 1.4, dist);
    c.r = clamp(c.r + mask * shift * 0.1, 0.0, 1.0);
    c.b = clamp(c.b - mask * shift * 0.1, 0.0, 1.0);
    return c;
}

// ── Pass 15: Chemical Irregularity ───────────────────────────────────
vec3 applyChemicalIrregularity(vec3 c, vec2 uv, float amount, float time) {
    if (amount < 0.001) return c;
    float n = hash(uv * 7.3 + vec2(time * 0.1, time * 0.07));
    float n2 = hash(uv * 13.7 + vec2(time * 0.13, time * 0.09));
    c.r = clamp(c.r + (n - 0.5) * amount * 0.04, 0.0, 1.0);
    c.g = clamp(c.g + (n2 - 0.5) * amount * 0.02, 0.0, 1.0);
    return c;
}

// ── Pass 16: Paper Texture ────────────────────────────────────────────
vec3 applyPaperTexture(vec3 c, vec2 uv, float amount, float time) {
    if (amount < 0.001) return c;
    float n = hash(floor(uv * 200.0) / 200.0 + vec2(time * 0.01));
    float paper = mix(0.95, 1.05, n);
    return clamp(c * paper * (1.0 + amount * 0.1) - vec3(amount * 0.02), 0.0, 1.0);
}

// ── Pass 17: Film Grain（亮度依赖 + grainSize 控制）─────────────────────
vec3 applyGrain(vec3 c, vec2 uv, float amount, float time, float grainSz) {
    if (amount < 0.001) return c;
    vec2 grainUV = uv / max(grainSz * uTexelSize * 800.0, vec2(0.001));
    float grain = hash(grainUV + vec2(time * 0.1)) - 0.5;
    grain += (hash(grainUV * 1.7 + vec2(time * 0.07, time * 0.13)) - 0.5) * 0.5;
    grain *= 0.667;
    float lum = luminance(c);
    float lumMask = 1.0 - pow(abs(lum * 2.0 - 1.0), 2.0);
    lumMask = mix(0.3, 1.0, lumMask);
    return clamp(c + grain * amount * 0.25 * lumMask, 0.0, 1.0);
}

// ── Pass 18: Digital Noise（成片专用：hash 暗部增强噪点）────────────────────
vec3 applyNoise(vec3 c, vec2 uv, float amount, float time) {
    if (amount < 0.001) return c;
    float lum   = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float noise = hash(uv * 800.0 + vec2(time)) - 0.5;
    float dark  = 1.0 - lum;
    return clamp(c + noise * amount * 0.2 * dark, 0.0, 1.0);
}

// ── Pass 19: Vignette（smoothstep 暗角，与预览统一）─────────────────────────
vec3 applyVignette(vec3 c, vec2 uv, float amount) {
    if (amount < 0.001) return c;
    vec2 d = uv - 0.5;
    float dist = length(d) * 2.0;
    float vignette = 1.0 - smoothstep(1.0 - amount, 1.5, dist) * amount;
    return clamp(c * vignette, 0.0, 1.0);
}

// ── 主函数 ────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;

    // Pass 0: 鱼眼模式 — UV 重映射 + 圆形遮罩（与预览 Shader 完全一致）
    bool isFisheye = uFisheyeMode > 0.5;
    if (isFisheye) {
        vec2 fUV = fisheyeUV(uv, uAspectRatio);
        if (fUV.x < 0.0) {
            fragColor = vec4(0.0, 0.0, 0.0, 1.0);
            return;
        }
        uv = fUV;
    }

    // Pass 1: 色差
    vec3 color = applyChromaticAberration(uInputTexture, uv, uChromaticAberration);

    // Pass 1.5: 曝光补偿（在色温之前应用，模拟相机 EV 补偿）
    if (uExposureOffset != 0.0) {
        color *= pow(2.0, uExposureOffset);
        color = clamp(color, 0.0, 1.0);
    }

    // Pass 2: 色温 + Tint
    color = applyTemperature(color, uTemperatureShift);
    color = applyTint(color, uTintShift);

    // Pass 3: 黑场/白场
    color = applyBlacksWhites(color, uBlacks, uWhites);

    // Pass 4: 高光/阴影
    color = applyHighlightsShadows(color, uHighlights, uShadows);

    // Pass 5: 对比度
    color = applyContrast(color, uContrast);

    // Pass 6: Clarity
    color = applyClarity(color, uClarity, uInputTexture, uv);

    // Pass 7: 饱和度 + Vibrance
    color = applySaturation(color, uSaturation);
    color = applyVibrance(color, uVibrance);

    // Pass 8: RGB 通道偏移
    color = applyColorBias(color, uColorBiasR, uColorBiasG, uColorBiasB);

    // Pass 9: Bloom（空间扩散光晕）
    color = applyBloom(color, uBloomAmount, uv);

    // Pass 10: Halation（红橙色胶片辉光）
    color = applyHalation(color, uHalationAmount, uv);

    // Pass 11: Highlight Rolloff（成片专属）
    color = applyHighlightRolloff(color, uHighlightRolloff);

    // Pass 11b: Highlight Rolloff 2（FXN-R 专属）
    if (uHighlightRolloff2 > 0.0) {
        color = applyCaptureHighlightRolloff2(color, uHighlightRolloff2);
    }

    // Pass 11c: Tone Curve（FXN-R 专属）
    if (uToneCurveStrength > 0.0) {
        vec3 curved = vec3(
            captureApplyToneCurve(color.r),
            captureApplyToneCurve(color.g),
            captureApplyToneCurve(color.b)
        );
        color = mix(color, curved, uToneCurveStrength);
    }

    // Pass 12: Center Gain（成片专属）
    color = applyCenterGain(color, uv, uCenterGain);

    // Pass 13: 肤色保护（成片专属）
    color = applySkinProtect(color, uSkinHueProtect, uSkinSatProtect, uSkinLumaSoften, uSkinRedLimit);

    // Pass 14: Edge Falloff + Corner Warm（成片专属）
    color = applyEdgeFalloff(color, uv, uEdgeFalloff);
    color = applyCornerWarm(color, uv, uCornerWarmShift);

    // Pass 14b: Development Softness（显影柔化）
    color = applyDevelopmentSoften(color, uv, uDevelopmentSoftness);

    // Pass 15: Chemical Irregularity（成片专属）
    color = applyChemicalIrregularity(color, uv, uChemicalIrregularity, uTime);

    // Pass 16: Paper Texture（成片专属）
    color = applyPaperTexture(color, uv, uPaperTexture, uTime);

    // Pass 17: Film Grain（亮度依赖 + grainSize）
    color = applyGrain(color, uv, uGrainAmount, uTime, uGrainSize);

    // Pass 18: Digital Noise
    color = applyNoise(color, uv, uNoiseAmount, uTime);

    // Pass 18b: Luminance Noise
    if (uLuminanceNoise > 0.0) {
        float ln = hash(uv * 600.0 + vec2(uTime + 1.7)) - 0.5;
        color = clamp(color + ln * uLuminanceNoise * 0.15, 0.0, 1.0);
    }
    // Pass 18c: Chroma Noise
    if (uChromaNoise > 0.0) {
        float cr = hash(uv * 500.0 + vec2(uTime + 3.1)) - 0.5;
        float cg = hash(uv * 500.0 + vec2(uTime + 5.3)) - 0.5;
        float cb = hash(uv * 500.0 + vec2(uTime + 7.7)) - 0.5;
        color = clamp(color + vec3(cr, cg, cb) * uChromaNoise * 0.08, 0.0, 1.0);
    }

    // Pass 20: Fade（褒色）
    if (uFadeAmount > 0.0) {
        color = color * (1.0 - uFadeAmount) + uFadeAmount;
        float fadeLum = luminance(color);
        float hlCompress = smoothstep(0.8, 1.0, fadeLum) * uFadeAmount * 0.3;
        color = clamp(color - hlCompress, 0.0, 1.0);
    }

    // Pass 21: Split Toning（分离色调）
    if (length(uShadowTint) + length(uHighlightTint) > 0.001) {
        float stLum = luminance(color);
        float shadowMask = 1.0 - smoothstep(0.0, uSplitToneBalance, stLum);
        float highlightMask = smoothstep(uSplitToneBalance, 1.0, stLum);
        color = clamp(color + uShadowTint * shadowMask + uHighlightTint * highlightMask, 0.0, 1.0);
    }

    // Pass 22: Light Leak（GPU 漏光）
    if (uLightLeakAmount > 0.001) {
        float angle = hash(vec2(uLightLeakSeed, uLightLeakSeed * 0.7)) * 6.2832;
        vec2 leakCenter = vec2(0.5 + cos(angle) * 0.5, 0.5 + sin(angle) * 0.5);
        float dist = length(uv - leakCenter);
        float leak = smoothstep(0.8, 0.0, dist) * uLightLeakAmount;
        float hue = hash(vec2(uLightLeakSeed * 1.3, uLightLeakSeed * 2.1));
        vec3 leakColor = mix(vec3(1.0, 0.4, 0.1), vec3(1.0, 0.8, 0.2), hue);
        color = clamp(1.0 - (1.0 - color) * (1.0 - leakColor * leak), 0.0, 1.0);
    }

    // Pass 23: Vignette
    // 鱼眼模式下不叠加额外暗角，圆形边缘已有自然渐暗（与预览 Shader 一致）
    if (!isFisheye) {
        float vigTotal = min(uVignetteAmount + uLensVignette, 1.0);
        color = applyVignette(color, uv, vigTotal);
    }

    fragColor = vec4(color, 1.0);
}"""

        // 全屏四边形顶点数据（位置 + UV）
        // FIX: V 坐标翻转（v=1 对应底部，v=0 对应顶部），补偿 GLUtils.texImage2D
        // 将 Bitmap 行序（上→下）直接上传到纹理行序（下→上）导致的 Y 翻转。
        // 不翻转 V 坐标时，输出图像始终上下颠倒。
        private val QUAD_VERTICES = floatArrayOf(
            // x,    y,    u,    v
            -1.0f, -1.0f, 0.0f, 1.0f,
             1.0f, -1.0f, 1.0f, 1.0f,
            -1.0f,  1.0f, 0.0f, 0.0f,
             1.0f,  1.0f, 1.0f, 0.0f,
        )
    }

    // ── EGL 状态 ──────────────────────────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // ── GL 状态 ───────────────────────────────────────────────────────────
    private var program: Int = 0
    private var vbo: Int = 0
    private var fbo: Int = 0
    private var renderTex: Int = 0

    // uniform 位置缓存
    private var uInputTexture = -1
    private var uTexelSize = -1
    private var uContrast = -1
    private var uSaturation = -1
    private var uTemperatureShift = -1
    private var uTintShift = -1
    private var uHighlights = -1
    private var uShadows = -1
    private var uWhites = -1
    private var uBlacks = -1
    private var uClarity = -1
    private var uVibrance = -1
    private var uColorBiasR = -1
    private var uColorBiasG = -1
    private var uColorBiasB = -1
    private var uGrainAmount = -1
    private var uNoiseAmount = -1
    private var uVignetteAmount = -1
    private var uLensVignette = -1
    private var uChromaticAberration = -1
    private var uBloomAmount = -1
    private var uHalationAmount = -1
    private var uTime = -1
    private var uHighlightRolloff = -1
    private var uHighlightRolloff2 = -1
    private var uToneCurveStrength = -1
    private var uPaperTexture = -1
    private var uEdgeFalloff = -1
    private var uExposureVariation = -1
    private var uCornerWarmShift = -1
    private var uCenterGain = -1
    private var uDevelopmentSoftness = -1
    private var uChemicalIrregularity = -1
    private var uSkinHueProtect = -1
    private var uSkinSatProtect = -1
    private var uSkinLumaSoften = -1
    private var uSkinRedLimit = -1
    private var uGrainSize = -1
    private var uLuminanceNoise = -1
    private var uChromaNoise = -1
    private var uFadeAmount = -1
    private var uShadowTint = -1
    private var uHighlightTint = -1
    private var uSplitToneBalance = -1
    private var uLightLeakAmount = -1
    private var uLightLeakSeed = -1
    private var uExposureOffset = -1
    private var uFisheyeMode = -1
    private var uAspectRatio = -1

    private var currentWidth = 0
    private var currentHeight = 0
    private var initialized = false

    // ── 公开接口 ──────────────────────────────────────────────────────────

    /**
     * 处理图像文件，返回处理后的 JPEG 文件路径
     *
     * @param filePath 原始 JPEG 文件路径
     * @param params   来自 Dart 层的参数字典
     * @return 处理后的 JPEG 文件路径，失败时返回 null
     */
    fun processImage(filePath: String, params: Map<String, Any>): String? {
        return try {
            // 1. 解码原始 JPEG
            val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
            val rawBitmap = BitmapFactory.decodeFile(filePath, options)
                ?: return null.also { Log.e(TAG, "Failed to decode: $filePath") }

            // ── FIX: 读取 EXIF Orientation 并旋转/翻转 Bitmap ──────────────────
            // BitmapFactory.decodeFile 不会自动应用 EXIF 旋转，
            // 导致所有带 EXIF 旋转标记的照片（前置/后置均有）方向错误。
            // EXIF Orientation 可表达 8 种变换（旋转+镜像），而 Dart 层的
            // deviceQuarter 只能表达 4 种旋转，无法处理前置摄像头的镜像翻转。
            // 因此必须在此处通过 EXIF 完整修正方向，Dart 层在 GPU 处理成功后
            // 跳过 deviceQuarter 旋转，避免双重旋转。
            val inBitmap = applyExifRotation(rawBitmap, filePath)
            if (inBitmap !== rawBitmap) rawBitmap.recycle()

            val width = inBitmap.width
            val height = inBitmap.height

            // 2. 初始化 EGL + GL（如果尺寸变化则重建 FBO）
            ensureGL(width, height)

            // 3. 上传输入图像为 GL 纹理
            val inputTex = uploadBitmapToTexture(inBitmap)
            inBitmap.recycle()

            // 4. 绑定 FBO，执行渲染
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
            GLES30.glViewport(0, 0, width, height)
            GLES30.glUseProgram(program)

            // 绑定输入纹理
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTex)
            GLES30.glUniform1i(uInputTexture, 0)
            GLES30.glUniform2f(uTexelSize, 1.0f / width, 1.0f / height)

            // 设置所有 uniform 参数
            setUniforms(params)

            // 绑定 VBO 并绘制全屏四边形
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
            val posLoc = GLES30.glGetAttribLocation(program, "aPosition")
            val uvLoc  = GLES30.glGetAttribLocation(program, "aTexCoord")
            GLES30.glEnableVertexAttribArray(posLoc)
            GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, 16, 0)
            GLES30.glEnableVertexAttribArray(uvLoc)
            GLES30.glVertexAttribPointer(uvLoc, 2, GLES30.GL_FLOAT, false, 16, 8)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
            GLES30.glFinish()

            // 5. PBO 异步回读像素（GPU→CPU，避免同步阻塞）
            // V 坐标已在 QUAD_VERTICES 中翻转，glReadPixels 读出的数据已是正向，无需 flipVertically。
            val pboArr = IntArray(1)
            GLES30.glGenBuffers(1, pboArr, 0)
            val pbo = pboArr[0]
            val pixelBytes = width * height * 4
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pbo)
            GLES30.glBufferData(GLES30.GL_PIXEL_PACK_BUFFER, pixelBytes, null, GLES30.GL_STREAM_READ)
            // 异步发起回读请求（GPU 继续执行其他工作）
            GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, 0)

            // 6. 释放临时纹理（在 GPU 传输期间并行执行）
            GLES30.glDeleteTextures(1, intArrayOf(inputTex), 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

            // 7. Map PBO 读取像素（此时 GPU 传输已完成）
            val mappedBuf = GLES30.glMapBufferRange(
                GLES30.GL_PIXEL_PACK_BUFFER, 0, pixelBytes,
                GLES30.GL_MAP_READ_BIT
            ) as? java.nio.ByteBuffer

            val outBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            if (mappedBuf != null) {
                // V 坐标已翻转，直接写入 Bitmap，无需 flipVertically（节省 ~40ms @ 12MP）
                outBitmap.copyPixelsFromBuffer(mappedBuf)
                GLES30.glUnmapBuffer(GLES30.GL_PIXEL_PACK_BUFFER)
            } else {
                // PBO map 失败，降级为同步 glReadPixels
                Log.w(TAG, "PBO map failed, falling back to synchronous glReadPixels")
                GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
                val fallbackBuf = ByteBuffer.allocateDirect(width * height * 4).apply { order(ByteOrder.nativeOrder()) }
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
                GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, fallbackBuf)
                fallbackBuf.rewind()
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
                outBitmap.copyPixelsFromBuffer(fallbackBuf)
            }
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
            GLES30.glDeleteBuffers(1, pboArr, 0)

            // 8. 编码为 JPEG（质量 88：人眼不可分辨，文件体积减少 ~15%）
            val outputFile = File(context.cacheDir, "gpu_${File(filePath).name}")
            FileOutputStream(outputFile).use { fos ->
                outBitmap.compress(Bitmap.CompressFormat.JPEG, 88, fos)
            }
            outBitmap.recycle()

            Log.d(TAG, "GL GPU processing complete: ${outputFile.absolutePath}")
            outputFile.absolutePath

        } catch (e: Exception) {
            Log.e(TAG, "GL GPU processing failed", e)
            null
        }
    }

    fun destroy() {
        if (!initialized) return
        if (vbo != 0) GLES30.glDeleteBuffers(1, intArrayOf(vbo), 0)
        if (fbo != 0) GLES30.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
        if (renderTex != 0) GLES30.glDeleteTextures(1, intArrayOf(renderTex), 0)
        if (program != 0) GLES30.glDeleteProgram(program)
        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(eglDisplay, eglSurface)
        EGL14.eglDestroyContext(eglDisplay, eglContext)
        EGL14.eglTerminate(eglDisplay)
        initialized = false
    }

    // ── 私有实现 ──────────────────────────────────────────────────────────

    private fun ensureGL(width: Int, height: Int) {
        if (!initialized) {
            initEGL(width, height)
            initGL()
            initialized = true
        } else if (width != currentWidth || height != currentHeight) {
            // 尺寸变化，重建 FBO
            rebuildFBO(width, height)
        }
    }

    private fun initEGL(width: Int, height: Int) {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        EGL14.eglInitialize(eglDisplay, null, 0, null, 0)

        val attribList = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, 1, numConfigs, 0)
        val config = configs[0]!!

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)

        // 使用 1x1 PBuffer Surface（不绑定图像尺寸），避免每次尺寸变化时重建 EGL context。
        // 实际渲染目标是 FBO（Framebuffer Object），PBuffer 只用于激活 EGL context。
        val pbufferAttribs = intArrayOf(
            EGL14.EGL_WIDTH, 1,
            EGL14.EGL_HEIGHT, 1,
            EGL14.EGL_NONE
        )
        eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, config, pbufferAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        currentWidth = width
        currentHeight = height
    }

    private fun initGL() {
        // 编译着色器
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glLinkProgram(program)
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)

        // 缓存所有 uniform 位置
        cacheUniformLocations()

        // 创建 VBO
        val vboArr = IntArray(1)
        GLES30.glGenBuffers(1, vboArr, 0)
        vbo = vboArr[0]
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        val buf = ByteBuffer.allocateDirect(QUAD_VERTICES.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply { put(QUAD_VERTICES); rewind() }
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, QUAD_VERTICES.size * 4, buf, GLES30.GL_STATIC_DRAW)

        // 创建 FBO + 渲染目标纹理
        buildFBO(currentWidth, currentHeight)
    }

    private fun buildFBO(width: Int, height: Int) {
        val texArr = IntArray(1)
        GLES30.glGenTextures(1, texArr, 0)
        renderTex = texArr[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, renderTex)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)

        val fboArr = IntArray(1)
        GLES30.glGenFramebuffers(1, fboArr, 0)
        fbo = fboArr[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, renderTex, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
    }

    private fun rebuildFBO(width: Int, height: Int) {
        GLES30.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
        GLES30.glDeleteTextures(1, intArrayOf(renderTex), 0)
        buildFBO(width, height)
        currentWidth = width
        currentHeight = height
    }

    private fun cacheUniformLocations() {
        fun loc(name: String) = GLES30.glGetUniformLocation(program, name)
        uInputTexture = loc("uInputTexture")
        uTexelSize = loc("uTexelSize")
        uContrast = loc("uContrast")
        uSaturation = loc("uSaturation")
        uTemperatureShift = loc("uTemperatureShift")
        uTintShift = loc("uTintShift")
        uHighlights = loc("uHighlights")
        uShadows = loc("uShadows")
        uWhites = loc("uWhites")
        uBlacks = loc("uBlacks")
        uClarity = loc("uClarity")
        uVibrance = loc("uVibrance")
        uColorBiasR = loc("uColorBiasR")
        uColorBiasG = loc("uColorBiasG")
        uColorBiasB = loc("uColorBiasB")
        uGrainAmount = loc("uGrainAmount")
        uNoiseAmount = loc("uNoiseAmount")
        uVignetteAmount = loc("uVignetteAmount")
        uLensVignette = loc("uLensVignette")
        uChromaticAberration = loc("uChromaticAberration")
        uBloomAmount = loc("uBloomAmount")
        uHalationAmount = loc("uHalationAmount")
        uTime = loc("uTime")
        uHighlightRolloff = loc("uHighlightRolloff")
        uHighlightRolloff2 = loc("uHighlightRolloff2")
        uToneCurveStrength = loc("uToneCurveStrength")
        uPaperTexture = loc("uPaperTexture")
        uEdgeFalloff = loc("uEdgeFalloff")
        uExposureVariation = loc("uExposureVariation")
        uCornerWarmShift = loc("uCornerWarmShift")
        uCenterGain = loc("uCenterGain")
        uDevelopmentSoftness = loc("uDevelopmentSoftness")
        uChemicalIrregularity = loc("uChemicalIrregularity")
        uSkinHueProtect = loc("uSkinHueProtect")
        uSkinSatProtect = loc("uSkinSatProtect")
        uSkinLumaSoften = loc("uSkinLumaSoften")
        uSkinRedLimit = loc("uSkinRedLimit")
        uGrainSize = loc("uGrainSize")
        uLuminanceNoise = loc("uLuminanceNoise")
        uChromaNoise = loc("uChromaNoise")
        uFadeAmount = loc("uFadeAmount")
        uShadowTint = loc("uShadowTint")
        uHighlightTint = loc("uHighlightTint")
        uSplitToneBalance = loc("uSplitToneBalance")
        uLightLeakAmount = loc("uLightLeakAmount")
        uLightLeakSeed = loc("uLightLeakSeed")
        uExposureOffset = loc("uExposureOffset")
        uFisheyeMode = loc("uFisheyeMode")
        uAspectRatio = loc("uAspectRatio")
    }

    private fun setUniforms(params: Map<String, Any>) {
        fun f(key: String, default: Float = 0.0f): Float = when (val v = params[key]) {
            is Double -> v.toFloat()
            is Float  -> v
            is Int    -> v.toFloat()
            is Long   -> v.toFloat()
            else      -> default
        }
        GLES30.glUniform1f(uContrast, f("contrast", 1.0f))
        GLES30.glUniform1f(uSaturation, f("saturation", 1.0f))
        GLES30.glUniform1f(uTemperatureShift, f("temperatureShift"))
        GLES30.glUniform1f(uTintShift, f("tintShift"))
        GLES30.glUniform1f(uHighlights, f("highlights"))
        GLES30.glUniform1f(uShadows, f("shadows"))
        GLES30.glUniform1f(uWhites, f("whites"))
        GLES30.glUniform1f(uBlacks, f("blacks"))
        GLES30.glUniform1f(uClarity, f("clarity"))
        GLES30.glUniform1f(uVibrance, f("vibrance"))
        GLES30.glUniform1f(uColorBiasR, f("colorBiasR"))
        GLES30.glUniform1f(uColorBiasG, f("colorBiasG"))
        GLES30.glUniform1f(uColorBiasB, f("colorBiasB"))
        GLES30.glUniform1f(uGrainAmount, f("grainAmount"))
        GLES30.glUniform1f(uNoiseAmount, f("noiseAmount"))
        GLES30.glUniform1f(uVignetteAmount, f("vignetteAmount"))
        GLES30.glUniform1f(uLensVignette, f("lensVignette"))
        GLES30.glUniform1f(uChromaticAberration, f("chromaticAberration"))
        GLES30.glUniform1f(uBloomAmount, f("bloomAmount"))
        GLES30.glUniform1f(uHalationAmount, f("halationAmount"))
        GLES30.glUniform1f(uTime, System.currentTimeMillis().toFloat() / 1000.0f)
        GLES30.glUniform1f(uHighlightRolloff, f("highlightRolloff"))
        GLES30.glUniform1f(uHighlightRolloff2, f("highlightRolloff2"))
        GLES30.glUniform1f(uToneCurveStrength, f("toneCurveStrength"))
        GLES30.glUniform1f(uPaperTexture, f("paperTexture"))
        GLES30.glUniform1f(uEdgeFalloff, f("edgeFalloff"))
        GLES30.glUniform1f(uExposureVariation, f("exposureVariation"))
        GLES30.glUniform1f(uCornerWarmShift, f("cornerWarmShift"))
        GLES30.glUniform1f(uCenterGain, f("centerGain"))
        GLES30.glUniform1f(uDevelopmentSoftness, f("developmentSoftness"))
        GLES30.glUniform1f(uChemicalIrregularity, f("chemicalIrregularity"))
        GLES30.glUniform1f(uSkinHueProtect, f("skinHueProtect"))
        GLES30.glUniform1f(uSkinSatProtect, f("skinSatProtect", 1.0f))
        GLES30.glUniform1f(uSkinLumaSoften, f("skinLumaSoften"))
        GLES30.glUniform1f(uSkinRedLimit, f("skinRedLimit", 1.0f))
        GLES30.glUniform1f(uGrainSize, f("grainSize", 1.0f))
        GLES30.glUniform1f(uLuminanceNoise, f("luminanceNoise"))
        GLES30.glUniform1f(uChromaNoise, f("chromaNoise"))
        GLES30.glUniform1f(uFadeAmount, f("fadeAmount"))
        GLES30.glUniform3f(uShadowTint, f("shadowTintR"), f("shadowTintG"), f("shadowTintB"))
        GLES30.glUniform3f(uHighlightTint, f("highlightTintR"), f("highlightTintG"), f("highlightTintB"))
        GLES30.glUniform1f(uSplitToneBalance, f("splitToneBalance", 0.5f))
        GLES30.glUniform1f(uLightLeakAmount, f("lightLeakAmount"))
        GLES30.glUniform1f(uLightLeakSeed, f("lightLeakSeed", System.currentTimeMillis().toFloat() / 1000.0f))
        GLES30.glUniform1f(uExposureOffset, f("exposureOffset"))
        GLES30.glUniform1f(uFisheyeMode, f("fisheyeMode"))
        // FIX: aspect must be min(w,h)/max(w,h) (<= 1.0) so fisheyeUV produces a round circle.
        // Capture images on Android are portrait (height > width), so w/h < 1.0 is already
        // correct, but we use min/max for safety (matches CameraGLRenderer and iOS MetalRenderer).
        val rawAr = if (f("aspectRatio") > 0.001f) f("aspectRatio")
                    else if (currentHeight > 0) currentWidth.toFloat() / currentHeight.toFloat()
                    else 1.0f
        val ar = if (rawAr > 1.0f) 1.0f / rawAr else rawAr  // ensure <= 1.0
        GLES30.glUniform1f(uAspectRatio, ar)
    }

    private fun uploadBitmapToTexture(bitmap: Bitmap): Int {
        val texArr = IntArray(1)
        GLES30.glGenTextures(1, texArr, 0)
        val tex = texArr[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        android.opengl.GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
        return tex
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            Log.e(TAG, "Shader compile error: ${GLES30.glGetShaderInfoLog(shader)}")
        }
        return shader
    }

    /**
     * 读取 JPEG 文件的 EXIF Orientation 标签，返回旋转/翻转后的 Bitmap。
     * 如果无需旋转则返回原 Bitmap（同一引用）。
     */
    private fun applyExifRotation(bitmap: Bitmap, filePath: String): Bitmap {
        return try {
            val exif = ExifInterface(filePath)
            val orientation = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
            val matrix = Matrix()
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90  -> matrix.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL   -> matrix.preScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    matrix.postRotate(90f)
                    matrix.preScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    matrix.postRotate(270f)
                    matrix.preScale(-1f, 1f)
                }
                else -> return bitmap // ORIENTATION_NORMAL or ORIENTATION_UNDEFINED
            }
            val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            Log.d(TAG, "EXIF orientation=$orientation, rotated ${bitmap.width}x${bitmap.height} -> ${rotated.width}x${rotated.height}")
            rotated
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read EXIF orientation: ${e.message}")
            bitmap
        }
    }

    private fun flipVertically(buf: ByteBuffer, width: Int, height: Int): ByteBuffer {
        val result = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
        val rowSize = width * 4
        val row = ByteArray(rowSize)
        for (y in 0 until height) {
            buf.position((height - 1 - y) * rowSize)
            buf.get(row)
            result.put(row)
        }
        result.rewind()
        return result
    }
}
