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
import java.io.ByteArrayInputStream
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
 *   Pass 3:  LUT / 基础色彩映射
 *   Pass 4:  饱和度 + Vibrance + RGB 通道偏移 / B&W Mixer
 *   Pass 5:  对比度 + Tone Curve + Mid Gray + Filmic Tone Map
 *   Pass 6:  黑场/白场 + 高光/阴影压缩 + Dehaze
 *   Pass 7:  Highlight Rolloff（高光柔和滚落，成片专属）
 *   Pass 8:  Bloom + Halation + Highlight Warm
 *   Pass 9:  Clarity / Development Softness
 *   Pass 10: Center Gain / Skin Protection / Edge Falloff
 *   Pass 11: Chemical Irregularity / Paper Texture / Fade / Split Tone
 *   Pass 12: Film Grain + Digital Noise
 *   Pass 13: Light Leak + Vignette
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
    // OpenGL 坐标系 Y 轴与图像坐标系相反，在 vertex shader 中翻转
    // 避免 glReadPixels 后的 CPU flipVertically 操作（节省 200~400ms）
    vTexCoord = vec2(aTexCoord.x, 1.0 - aTexCoord.y);
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
uniform float uGrainPatternStrength;
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
uniform int   uToneCurveCount;
uniform float uToneCurveX[16];
uniform float uToneCurveY[16];
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
uniform float uGrainRoughness;       // 颗粒粗糙度（0.0~1.0）
uniform float uGrainLumaBias;        // 颗粒亮度偏置
uniform float uGrainColorVariation;  // 彩色颗粒 RGB 轻微分离
uniform float uLuminanceNoise;       // 亮度噪声
uniform float uChromaNoise;           // 色度噪声
uniform float uDehaze;
uniform float uHighlightWarmAmount;
uniform float uToneMapToe;
uniform float uToneMapShoulder;
uniform float uToneMapStrength;
uniform float uMidGrayDensity;
uniform float uHighlightRolloffPivot;
uniform float uHighlightRolloffSoftKnee;
uniform float uTopBottomBias;
uniform float uLeftRightBias;
uniform float uBwMixerEnabled;
uniform vec3  uBwChannelMixer;
// ── Fade / Split Toning / Light Leak ──
uniform float uFadeAmount;
uniform vec3  uShadowTint;
uniform vec3  uHighlightTint;
uniform float uSplitToneBalance;
uniform float uLightLeakAmount;
uniform float uLightLeakSeed;
uniform float uDustAmount;
uniform float uScratchAmount;
uniform float uExposureOffset;        // 用户曝光补偿（-2.0~+2.0）
uniform float uFisheyeMode;           // 1.0=启用鱼眼投影, 0.0=普通模式
uniform float uCircularFisheye;       // 1.0=圆形裁切, 0.0=保留矩形画面
uniform float uAspectRatio;           // 宽/高，用于鱼眼圆形不变形
uniform float uLensDistortion;        // 轻量桶形畸变（非圆形鱼眼）
// ── LUT 参数 ────────────────────────────────────────────────────────────────────────────────
uniform sampler2D uLutTexture;        // LUT 2D 纹理（宽=N*N，高=N）
uniform float uLutEnabled;            // 1.0 = 启用 LUT
uniform float uLutStrength;           // LUT 混合强度（0.0~1.0）
uniform float uLutSize;               // LUT 边长（通常 33）
// ── Device Calibration（V3：设备级线性校准）──────────────────────────────────────────────────
uniform float uDeviceGamma;
uniform vec3  uDeviceWhiteScale;
uniform mat3  uDeviceCcm;
// ── 工具函数 ────────────────────────────────────────────────────────────────────────────────
float luminance(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}
// ── LUT 采样函数（与 iOS CameraShaders.metal sampleLUT 完全一致）
vec3 sampleLUT(sampler2D lut, vec3 color, float lutN) {
    float scale  = (lutN - 1.0) / lutN;
    float offset = 0.5 / lutN;
    vec3 lutCoord = color * scale + offset;
    float bSlice = lutCoord.b * (lutN - 1.0);
    float bLow   = floor(bSlice);
    float bHigh  = min(bLow + 1.0, lutN - 1.0);
    float bFrac  = bSlice - bLow;
    float texW   = lutN * lutN;
    float texH   = lutN;
    vec2 uvLow  = vec2((bLow  * lutN + lutCoord.r * (lutN - 1.0) + 0.5) / texW,
                       (lutCoord.g * (lutN - 1.0) + 0.5) / texH);
    vec2 uvHigh = vec2((bHigh * lutN + lutCoord.r * (lutN - 1.0) + 0.5) / texW,
                       (lutCoord.g * (lutN - 1.0) + 0.5) / texH);
    vec3 colLow  = texture(lut, uvLow).rgb;
    vec3 colHigh = texture(lut, uvHigh).rgb;
    return mix(colLow, colHigh, bFrac);
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

float noise(vec2 p, float seed) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash(i + seed);
    float b = hash(i + vec2(1.0, 0.0) + seed);
    float c = hash(i + vec2(0.0, 1.0) + seed);
    float d = hash(i + vec2(1.0, 1.0) + seed);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) +
           (c - a) * u.y * (1.0 - u.x) +
           (d - b) * u.x * u.y;
}
// ── 圆形鱼眼 UV 重映射（等距投影，与 CameraGLRenderer 完全一致）
// 返回 vec2(-1) 表示圆形以外区域
vec2 fisheyeUV(vec2 uv, float aspect) {
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r = length(p);
    // 与预览保持一致：缩小有效圆半径，增强圆形边界可见度。
    const float rMax = 0.98;
    if (r > rMax) return vec2(-1.0);
    float rn = r / rMax;
    float theta = rn * 1.5707963; // pi/2
    float phi = atan(p.y, p.x);
    float sinTheta = sin(theta);
    vec2 texCoord = vec2(sinTheta * cos(phi), sinTheta * sin(phi));
    return texCoord * 0.5 + 0.5;
}

vec2 fisheyeRectUV(vec2 uv, float aspect) {
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r = length(p);
    float rCorner = length(vec2(aspect, 1.0));
    float rn = clamp(r / max(rCorner, 0.0001), 0.0, 1.0);
    float theta = rn * 1.5707963;
    float phi = atan(p.y, p.x);
    float sinTheta = sin(theta);
    vec2 mapped = vec2(sinTheta * cos(phi), sinTheta * sin(phi));
    mapped.x /= max(aspect, 0.0001);
    return clamp(mapped * 0.5 + 0.5, vec2(0.0), vec2(1.0));
}

vec2 barrelDistortUV(vec2 uv, float strength, float aspect) {
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r2 = dot(p, p);
    float k = 1.0 + strength * 0.35 * r2;
    p *= k;
    p.x /= max(aspect, 0.0001);
    return p * 0.5 + 0.5;
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
    // Keep capture path aligned with preview shader intensity (0.003),
    // otherwise clarity can over-amplify highlights and cause white clipping.
    return clamp(c + detail * clarity * 0.003 * midMask, 0.0, 1.0);
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
vec3 applyDeviceCalibration(vec3 c, vec3 whiteScale, mat3 ccm, float gammaVal) {
    c = clamp(c * whiteScale, 0.0, 1.0);
    c = clamp(ccm * c, 0.0, 1.0);
    if (abs(gammaVal - 1.0) > 0.0001) {
        float invGamma = 1.0 / max(gammaVal, 0.001);
        c = pow(clamp(c, 0.0, 1.0), vec3(invGamma));
    }
    return clamp(c, 0.0, 1.0);
}

// ── Pass 9: Bloom（空间扩散光晕）───────────────────────────────────────────
vec3 applyBloom(vec3 c, float amount, vec2 uv) {
    if (amount < 0.001) return c;
    float bloomRadius = amount * 8.0;
    vec3 bloomColor = vec3(0.0);
    float totalWeight = 0.0;
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            vec2 offset = vec2(float(i), float(j)) * uTexelSize * bloomRadius;
            vec3 sample_c = texture(uInputTexture, uv + offset).rgb;
            float sLum = luminance(sample_c);
            float highlight = smoothstep(0.82, 0.98, sLum);
            float w = (i == 0 && j == 0) ? 4.0 : (abs(i) + abs(j) == 1 ? 2.0 : 1.0);
            bloomColor += sample_c * highlight * w;
            totalWeight += w;
        }
    }
    bloomColor /= totalWeight;
    bloomColor *= vec3(0.75, 0.68, 0.56);
    c = clamp(c + bloomColor * amount * 0.55, 0.0, 1.0);
    return c;
}
// ── Pass 10: Halation（红橙色胶片辉光，空间扩散）───────────────────────
vec3 applyHalation(vec3 c, float amount, vec2 uv) {
    if (amount < 0.001) return c;
    float haloRadius = amount * 12.0;
    vec3 haloColor = vec3(0.0);
    float totalWeight = 0.0;
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            if (abs(i) + abs(j) > 3) continue;
            vec2 offset = vec2(float(i), float(j)) * uTexelSize * haloRadius;
            vec3 sample_c = texture(uInputTexture, uv + offset).rgb;
            float sLum = luminance(sample_c);
            float highlight = smoothstep(0.84, 0.99, sLum);
            float dist = float(abs(i) + abs(j));
            float w = 1.0 / (1.0 + dist);
            haloColor += sample_c * highlight * w;
            totalWeight += w;
        }
    }
    haloColor /= totalWeight;
    float haloLum = luminance(haloColor);
    c.r = clamp(c.r + haloLum * amount * 0.55, 0.0, 1.0);
    c.g = clamp(c.g + haloLum * amount * 0.16, 0.0, 1.0);
    c.b = clamp(c.b + haloLum * amount * 0.02, 0.0, 1.0);
    return c;
}

// ── Pass 11: Highlight Rolloff ────────────────────────────────────
float applyHighlightRolloffScalar(float x, float amount, float pivot, float knee) {
    if (x <= pivot) return x;
    float t = clamp((x - pivot) / max(1e-5, 1.0 - pivot), 0.0, 1.0);
    t = smoothstep(0.0, 1.0, pow(t, 1.0 + knee));
    float compressed = pivot + (1.0 - pivot) * (1.0 - exp(-t * (1.0 + amount * 4.0)));
    return mix(x, compressed, amount);
}

vec3 applyHighlightRolloff(vec3 c, float rolloff, float pivot, float knee) {
    if (rolloff < 0.001) return c;
    float p = clamp(pivot, 0.52, 0.92);
    float k = clamp(knee, 0.0, 1.0);
    return clamp(vec3(
        applyHighlightRolloffScalar(c.r, rolloff, p, k),
        applyHighlightRolloffScalar(c.g, rolloff, p, k),
        applyHighlightRolloffScalar(c.b, rolloff, p, k)
    ), 0.0, 1.0);
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
    return mix(c, blurred, softness * 0.24);
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

// ── Pass 17: Film Grain（亮度依赖 + grainSize 控制）─────────────────────
vec3 applyGrain(vec3 c, vec2 uv, float amount, float time, float grainSz, float roughness) {
    if (amount < 0.001) return c;
    float gSize = clamp(grainSz, 0.55, 2.6);
    float rough = clamp(roughness, 0.0, 1.0);
    float lumaBias = clamp(uGrainLumaBias, 0.0, 1.0);
    float colorVar = clamp(uGrainColorVariation, 0.0, 0.5);
    vec2 baseScale = vec2(220.0 / gSize, 176.0 / gSize);
    float seed = 0.0;
    float fine = hash(uv * baseScale + vec2(0.17, 0.31) + vec2(seed));
    float mid = hash(uv * (baseScale * 0.35) + vec2(2.41, 1.73) + vec2(seed));
    float coarse = hash(uv * (baseScale * 0.12) + vec2(4.13, 3.19) + vec2(seed));
    float high = (fine - 0.5) * 0.60 + (mid - 0.5) * 0.30 + (coarse - 0.5) * 0.10;
    float low = ((hash(uv * (baseScale * 0.18) + vec2(6.31, 5.17) + vec2(seed)) - 0.5) * 2.0);
    float grain = high * mix(1.0, low * 0.65, rough);
    float lum = luminance(c);
    float dark = smoothstep(0.05, 0.25, lum);
    float bright = 1.0 - smoothstep(0.70, 0.95, lum);
    float midMask = dark * bright;
    float brightFalloff = 1.0 - smoothstep(0.75, 1.0, lum);
    float mask = mix(midMask, brightFalloff, lumaBias);
    mask *= (1.0 + fwidth(lum) * 2.0);
    vec2 vignetteVec = uv * 2.0 - 1.0;
    float vignetteMask = smoothstep(0.30, 1.0, dot(vignetteVec, vignetteVec));
    mask *= mix(1.0, 1.18, vignetteMask);
    float colorMix = smoothstep(0.2, 0.8, lum);
    float jitterR = (hash(uv * baseScale * 1.03 + vec2(1.7)) - 0.5) * colorVar;
    float jitterG = (hash(uv * baseScale * 1.11 + vec2(2.3)) - 0.5) * colorVar;
    float jitterB = (hash(uv * baseScale * 0.97 + vec2(3.1)) - 0.5) * colorVar;
    vec3 monoGrain = vec3(grain);
    vec3 colorGrain = vec3(grain + jitterR, grain + jitterG, grain + jitterB);
    vec3 grainRgb = mix(monoGrain, colorGrain, colorMix) * max(uGrainPatternStrength, 0.0);
    return clamp(c + grainRgb * amount * mask * 0.55, 0.0, 1.0);
}

// ── Pass 18: Digital Noise（成片专用：hash 暗部增强噪点）────────────────────
vec3 applyNoise(vec3 c, vec2 uv, float amount, float luminanceAmount, float chromaAmount, float time) {
    if (amount < 0.001) return c;
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float noiseMask = 1.0 - smoothstep(0.15, 0.75, lum);
    float ln = (hash(uv * 780.0 + vec2(time + 1.7)) - 0.5) * max(luminanceAmount, 0.0);
    float cr = (hash(uv * 811.0 + vec2(time + 3.1)) - 0.5) * max(chromaAmount, 0.0);
    float cg = (hash(uv * 853.0 + vec2(time + 5.3)) - 0.5) * max(chromaAmount, 0.0);
    float cb = (hash(uv * 887.0 + vec2(time + 7.7)) - 0.5) * max(chromaAmount, 0.0);
    vec3 sensorNoise = (vec3(ln) + vec3(cr, cg, cb)) * noiseMask;
    return clamp(c + sensorNoise * amount, 0.0, 1.0);
}

// ── Pass 19: Vignette（smoothstep 暗角，与预览统一）─────────────────────────
vec3 applyVignette(vec3 c, vec2 uv, float amount) {
    if (amount < 0.001) return c;
    vec2 d = uv - 0.5;
    float dist = length(d) * 2.0;
    float vignette = 1.0 - smoothstep(1.0 - amount, 1.5, dist) * amount;
    return clamp(c * vignette, 0.0, 1.0);
}

vec3 applyDirectionalBias(vec3 c, vec2 uv, float topBottomBias, float leftRightBias) {
    float directional = 1.0 +
        (uv.y - 0.5) * topBottomBias * 0.35 +
        (uv.x - 0.5) * leftRightBias * 0.35;
    return clamp(c * directional, 0.0, 1.0);
}

float lineDistance(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h);
}

float filmLuminance(vec3 c) {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

float dustLayer(vec2 uv, float seed, float density) {
    vec2 grid = floor(uv * 140.0);
    float rnd = hash(grid + seed);
    float appear = step(1.0 - density, rnd);
    vec2 center = (grid + vec2(hash(grid + seed * 1.3), hash(grid + seed * 2.1))) / 140.0;
    float d = length(uv - center);
    float r = mix(0.0015, 0.004, hash(grid + seed * 3.7));
    float soft = 1.0 - smoothstep(r * 0.6, r, d);
    return appear * soft;
}

float dustCluster(vec2 uv, float seed) {
    float n1 = noise(uv * 6.0 + seed, seed);
    float n2 = noise(uv * 18.0 + seed * 2.0, seed * 2.0);
    float cluster = n1 * 0.7 + n2 * 0.3;
    return smoothstep(0.6, 0.9, cluster);
}

float scratchLayer(vec2 uv, float seed, float amount) {
    float result = 0.0;
    float count = floor(amount * 4.0);
    for (int i = 0; i < 3; i++) {
        if (float(i) >= count) break;
        float s = seed + float(i) * 17.0;
        float x = hash(vec2(s, 0.0));
        float curve = sin(uv.y * 10.0 + s) * 0.002;
        float width = mix(0.0006, 0.002, hash(vec2(s, 1.0)));
        float line = 1.0 - smoothstep(width, width * 2.0, abs(uv.x - (x + curve)));
        float breakMask = step(0.3, hash(vec2(floor(uv.y * 40.0), s)));
        float variation = mix(0.5, 1.0, hash(vec2(floor(uv.y * 20.0), s)));
        result += line * breakMask * variation;
    }
    return result;
}

float stainLayer(vec2 uv, float seed) {
    float n = noise(uv * 2.5 + seed, seed);
    return smoothstep(0.65, 0.95, n);
}

float paperTexture(vec2 uv) {
    float p1 = noise(uv * 8.0, 0.0);
    float p2 = noise(uv * 32.0, 1.0);
    return p1 * 0.7 + p2 * 0.3;
}

vec3 applyFilmArtifacts(vec3 color, vec2 uv, float dustAmount, float scratchAmount, float paperAmount, float seed) {
    float luma = filmLuminance(color);
    float d = dustLayer(uv, seed, dustAmount);
    float cluster = dustCluster(uv, seed) * dustAmount * 0.6;
    float dustVis = smoothstep(0.1, 0.4, luma) * (1.0 - smoothstep(0.85, 1.0, luma));
    vec3 dustColor = (hash(uv + seed) < 0.7) ? vec3(-0.08) : vec3(0.06);
    color += dustColor * (d + cluster) * dustVis;

    float s = scratchLayer(uv, seed, scratchAmount);
    float scratchVis = smoothstep(0.2, 0.5, luma) * (1.0 - smoothstep(0.9, 1.0, luma));
    vec3 scratchColor = (hash(uv * 2.0 + seed) < 0.75) ? vec3(-0.12) : vec3(0.08);
    color += scratchColor * s * scratchVis;

    float stain = stainLayer(uv, seed);
    color *= 1.0 - stain * 0.03 * dustAmount;

    float p = paperTexture(uv);
    color += (p - 0.5) * 0.02 * paperAmount;
    return clamp(color, 0.0, 1.0);
}

vec3 applyDehaze(vec3 c, float amount) {
    if (amount < 0.001) return c;
    float minC = min(c.r, min(c.g, c.b));
    float maxC = max(c.r, max(c.g, c.b));
    float haze = clamp(minC * 0.65 + (1.0 - (maxC - minC)) * 0.35, 0.0, 1.0);
    float gain = 1.0 + amount * 0.55;
    float offset = haze * amount * 0.12;
    vec3 outColor = vec3(
        clamp((c.r - offset) * gain, 0.0, 1.0),
        clamp((c.g - offset) * gain, 0.0, 1.0),
        clamp((c.b - offset * 1.05) * gain, 0.0, 1.0)
    );
    return outColor;
}

float filmicCurve(float x, float toe, float shoulder) {
    float c = clamp(x, 0.0, 1.0);
    float t = clamp(toe, 0.0, 1.0);
    float s = clamp(shoulder, 0.0, 1.0);
    float a = 0.22 + s * 0.26;
    float b = 0.30 + t * 0.24;
    float c2 = 0.10 + t * 0.18;
    float d = 0.20 + s * 0.22;
    float e = 0.01;
    float f = 0.30 + s * 0.18;
    float y = ((c * (a * c + c2 * b) + d * e) / (c * (a * c + b) + d * f)) - e / f;
    float w = ((1.0 * (a * 1.0 + c2 * b) + d * e) / (1.0 * (a * 1.0 + b) + d * f)) - e / f;
    return clamp(y / max(w, 1e-4), 0.0, 1.0);
}

vec3 applyFilmicToneMap(vec3 c, float toe, float shoulder, float strength) {
    if (strength < 0.001) return c;
    vec3 mapped = vec3(
        filmicCurve(c.r, toe, shoulder),
        filmicCurve(c.g, toe, shoulder),
        filmicCurve(c.b, toe, shoulder)
    );
    return clamp(mix(c, mapped, clamp(strength, 0.0, 1.0)), 0.0, 1.0);
}

vec3 applyMidGrayDensity(vec3 c, float density) {
    if (abs(density) < 0.001) return c;
    float lum = luminance(c);
    float anchor = 0.18;
    float dist = abs(lum - anchor);
    float mask = exp(-dist * 10.0);
    float gain = exp2(clamp(density, -1.0, 1.0) * 0.8 * mask);
    return clamp(c * gain, 0.0, 1.0);
}

vec3 applyHighlightWarm(vec3 c, float amount) {
    if (amount < 0.001) return c;
    float lum = luminance(c);
    if (lum <= 0.55) return c;
    float mask = smoothstep(0.55, 1.0, lum) * clamp(amount, 0.0, 1.0);
    vec3 target = vec3(
        clamp(c.r + 0.08, 0.0, 1.0),
        clamp(c.g + 0.035, 0.0, 1.0),
        clamp(c.b - 0.045, 0.0, 1.0)
    );
    vec3 mixMask = vec3(mask, mask * 0.9, mask * 0.85);
    return clamp(mix(c, target, mixMask), 0.0, 1.0);
}

vec3 applyBwMixer(vec3 c, vec3 mixer, float enabled) {
    if (enabled < 0.5) return c;
    float y = dot(c, mixer);
    float clampedY = clamp(y, 0.0, 1.0);
    return vec3(clampedY);
}

float applyToneCurveDynamicValue(float x) {
    if (uToneCurveCount < 2) return x;
    float firstX = uToneCurveX[0];
    float firstY = uToneCurveY[0];
    if (x <= firstX) return firstY;
    float prevX = firstX;
    float prevY = firstY;
    for (int i = 1; i < 16; i++) {
        if (i >= uToneCurveCount) break;
        float nextX = uToneCurveX[i];
        float nextY = uToneCurveY[i];
        if (x <= nextX) {
            float span = max(nextX - prevX, 0.0001);
            float t = clamp((x - prevX) / span, 0.0, 1.0);
            return mix(prevY, nextY, t);
        }
        prevX = nextX;
        prevY = nextY;
    }
    return prevY;
}

vec3 applyDynamicToneCurve(vec3 c, float strength) {
    if (uToneCurveCount < 2 || strength < 0.001) return c;
    vec3 curved = vec3(
        applyToneCurveDynamicValue(c.r),
        applyToneCurveDynamicValue(c.g),
        applyToneCurveDynamicValue(c.b)
    );
    return mix(c, curved, strength);
}

// ── 主函数 ────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;

    // Pass 0: 鱼眼模式 — UV 重映射 + 圆形遮罩（与预览 Shader 完全一致）
    bool isFisheye = uFisheyeMode > 0.5;
    bool useCircularFisheye = uCircularFisheye > 0.5;
    if (isFisheye) {
        if (useCircularFisheye) {
            vec2 fUV = fisheyeUV(uv, uAspectRatio);
            if (fUV.x < 0.0) {
                fragColor = vec4(0.0, 0.0, 0.0, 1.0);
                return;
            }
            uv = fUV;
        } else {
            uv = fisheyeRectUV(uv, uAspectRatio);
        }
    } else if (abs(uLensDistortion) > 0.0001) {
        uv = clamp(barrelDistortUV(uv, uLensDistortion, uAspectRatio), vec2(0.0), vec2(1.0));
    }

    // Pass 1: 色差
    vec3 color = applyChromaticAberration(uInputTexture, uv, uChromaticAberration);

    // Pass 1.5: 曝光补偿（在色温之前应用，模拟相机 EV 补偿）
    if (uExposureOffset != 0.0) {
        color *= pow(2.0, uExposureOffset);
        color = clamp(color, 0.0, 1.0);
    }

    // Pass 1.75: 设备级色彩校准（白点缩放 + CCM + Gamma）
    color = applyDeviceCalibration(color, uDeviceWhiteScale, uDeviceCcm, uDeviceGamma);

    // Pass 2: 色温 + Tint
    color = applyTemperature(color, uTemperatureShift);
    color = applyTint(color, uTintShift);

    // Pass 3: LUT（基础色彩映射优先于影调与质感）
    if (uLutEnabled > 0.5) {
        vec3 lutColor = sampleLUT(uLutTexture, color, uLutSize);
        color = mix(color, lutColor, uLutStrength);
    }

    // Pass 4: 基础色彩塑形
    color = applySaturation(color, uSaturation);
    color = applyVibrance(color, uVibrance);
    color = applyColorBias(color, uColorBiasR, uColorBiasG, uColorBiasB);
    color = applyBwMixer(color, uBwChannelMixer, uBwMixerEnabled);

    // Pass 5: 全局影调骨架
    color = applyContrast(color, uContrast);
    if (uToneCurveStrength > 0.0) {
        if (uToneCurveCount >= 2) {
            color = applyDynamicToneCurve(color, uToneCurveStrength);
        } else {
            vec3 curved = vec3(
                captureApplyToneCurve(color.r),
                captureApplyToneCurve(color.g),
                captureApplyToneCurve(color.b)
            );
            color = mix(color, curved, uToneCurveStrength);
        }
    }
    color = applyMidGrayDensity(color, uMidGrayDensity);
    color = applyFilmicToneMap(
        color,
        uToneMapToe,
        uToneMapShoulder,
        uToneMapStrength
    );

    // Pass 6: 分区调整与雾度控制
    color = applyBlacksWhites(color, uBlacks, uWhites);
    color = applyHighlightsShadows(color, uHighlights, uShadows);
    color = applyDehaze(color, uDehaze);

    // Pass 7: Highlight Rolloff（高光末端专职压缩）
    color = applyHighlightRolloff(color, uHighlightRolloff, uHighlightRolloffPivot, uHighlightRolloffSoftKnee);
    if (uHighlightRolloff2 > 0.0) {
        color = applyCaptureHighlightRolloff2(color, uHighlightRolloff2);
    }

    // Pass 8: 高光光学响应
    color = applyBloom(color, uBloomAmount, uv);
    color = applyHalation(color, uHalationAmount, uv);
    color = applyHighlightWarm(color, uHighlightWarmAmount);

    // Pass 9: 细节塑形
    color = applyClarity(color, uClarity, uInputTexture, uv);
    color = applyDevelopmentSoften(color, uv, uDevelopmentSoftness);

    // Pass 10: 画面空间响应
    color = applyCenterGain(color, uv, uCenterGain);
    color = applySkinProtect(color, uSkinHueProtect, uSkinSatProtect, uSkinLumaSoften, uSkinRedLimit);
    color = applyEdgeFalloff(color, uv, uEdgeFalloff);
    color = applyCornerWarm(color, uv, uCornerWarmShift);
    color = applyDirectionalBias(color, uv, uTopBottomBias, uLeftRightBias);

    // Pass 11: 介质前置层
    color = applyChemicalIrregularity(color, uv, uChemicalIrregularity, uTime);
    if (uFadeAmount > 0.0) {
        color = color * (1.0 - uFadeAmount) + uFadeAmount;
        float fadeLum = luminance(color);
        float hlCompress = smoothstep(0.8, 1.0, fadeLum) * uFadeAmount * 0.3;
        color = clamp(color - hlCompress, 0.0, 1.0);
    }
    if (length(uShadowTint) + length(uHighlightTint) > 0.001) {
        float stLum = luminance(color);
        float shadowMask = 1.0 - smoothstep(0.0, uSplitToneBalance, stLum);
        float highlightMask = smoothstep(uSplitToneBalance, 1.0, stLum);
        color = clamp(color + uShadowTint * shadowMask + uHighlightTint * highlightMask, 0.0, 1.0);
    }

    // Pass 12: 质感层
    color = applyGrain(color, uv, uGrainAmount, uTime, uGrainSize, uGrainRoughness);
    color = applyNoise(color, uv, uNoiseAmount, uLuminanceNoise, uChromaNoise, uTime);

    // Pass 13: Artifacts / 光学成品层
    color = applyFilmArtifacts(color, uv, uDustAmount, uScratchAmount, uPaperTexture, uLightLeakSeed);
    if (uLightLeakAmount > 0.001) {
        float angle = hash(vec2(uLightLeakSeed, uLightLeakSeed * 0.7)) * 6.2832;
        vec2 leakCenter = vec2(0.5 + cos(angle) * 0.5, 0.5 + sin(angle) * 0.5);
        float dist = length(uv - leakCenter);
        float leak = smoothstep(0.8, 0.0, dist) * uLightLeakAmount;
        float hue = hash(vec2(uLightLeakSeed * 1.3, uLightLeakSeed * 2.1));
        vec3 leakColor = mix(vec3(1.0, 0.4, 0.1), vec3(1.0, 0.8, 0.2), hue);
        color = clamp(1.0 - (1.0 - color) * (1.0 - leakColor * leak), 0.0, 1.0);
    }

    if (!isFisheye || !useCircularFisheye) {
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
    private var pbo: Int = 0  // PBO for async glReadPixels (avoids GPU stall)

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
    private var uGrainPatternStrength = -1
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
    private var uToneCurveCount = -1
    private var uToneCurveX = -1
    private var uToneCurveY = -1
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
    private var uGrainRoughness = -1
    private var uGrainLumaBias = -1
    private var uGrainColorVariation = -1
    private var uLuminanceNoise = -1
    private var uChromaNoise = -1
    private var uDehaze = -1
    private var uHighlightWarmAmount = -1
    private var uToneMapToe = -1
    private var uToneMapShoulder = -1
    private var uToneMapStrength = -1
    private var uMidGrayDensity = -1
    private var uHighlightRolloffPivot = -1
    private var uHighlightRolloffSoftKnee = -1
    private var uTopBottomBias = -1
    private var uLeftRightBias = -1
    private var uBwMixerEnabled = -1
    private var uBwChannelMixer = -1
    private var uFadeAmount = -1
    private var uShadowTint = -1
    private var uHighlightTint = -1
    private var uSplitToneBalance = -1
    private var uLightLeakAmount = -1
    private var uLightLeakSeed = -1
    private var uDustAmount = -1
    private var uScratchAmount = -1
    private var uExposureOffset = -1
    private var uFisheyeMode = -1
    private var uCircularFisheye = -1
    private var uAspectRatio = -1
    private var uLensDistortion = -1
    // LUT uniform 位置缓存
    private var uLutTexture = -1
    private var uLutEnabled = -1
    private var uLutStrength = -1
    private var uLutSize = -1
    private var uDeviceGamma = -1
    private var uDeviceWhiteScale = -1
    private var uDeviceCcm = -1
    // LUT 纹理 ID（每次拍照时加载，处理完成后释放）
    private var lutTextureId: Int = 0

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
            val mirrorOutput = (params["mirrorOutput"] as? Boolean) ?: false
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
            val exifBitmap = applyExifRotation(rawBitmap, filePath)
            if (exifBitmap !== rawBitmap) rawBitmap.recycle()

            // 1b. 按 maxDimension 缩放（避免 GPU 处理全像素原图）
            val maxDim = (params["maxDimension"] as? Int) ?: 4096
            val srcMax = maxOf(exifBitmap.width, exifBitmap.height)
            val inBitmap = if (srcMax > maxDim) {
                val scale = maxDim.toFloat() / srcMax
                val newW = (exifBitmap.width * scale).toInt()
                val newH = (exifBitmap.height * scale).toInt()
                Log.d(TAG, "Scaled ${srcMax}px → ${maxDim}px (${newW}x${newH})")
                Bitmap.createScaledBitmap(exifBitmap, newW, newH, true)
                    .also { exifBitmap.recycle() }
            } else {
                exifBitmap
            }

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
            // 加载 LUT 纹理（若有 baseLut 参数）
            val baseLutPath = params["baseLut"] as? String
            if (!baseLutPath.isNullOrEmpty()) {
                val lutTex = loadLutTexture(baseLutPath, context)
                if (lutTex != 0) {
                    lutTextureId = lutTex
                    GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
                    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, lutTex)
                    GLES30.glUniform1i(uLutTexture, 1)
                    GLES30.glUniform1f(uLutEnabled, 1.0f)
                } else {
                    Log.w(TAG, "LUT not found: $baseLutPath, skipping LUT pass")
                }
            }
            // 绑定 VBO 并绘制全屏四边形形
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
            val posLoc = GLES30.glGetAttribLocation(program, "aPosition")
            val uvLoc  = GLES30.glGetAttribLocation(program, "aTexCoord")
            GLES30.glEnableVertexAttribArray(posLoc)
            GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, 16, 0)
            GLES30.glEnableVertexAttribArray(uvLoc)
            GLES30.glVertexAttribPointer(uvLoc, 2, GLES30.GL_FLOAT, false, 16, 8)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
            GLES30.glFinish()

            // 5. PBO 异步回读（避免 GPU stall，比 glReadPixels 快 300-600ms）
            // 原理：先用 PBO 发起 DMA 传输，CPU 继续执行释放纹理等工作，
            // 最后 glMapBufferRange 时 GPU 传输已完成，几乎无等待。
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pbo)
            GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, 0)

            // 6. 释放临时纹理（在 GPU 传输期间并行执行，节省 CPU 等待时间）
            GLES30.glDeleteTextures(1, intArrayOf(inputTex), 0)
            if (lutTextureId != 0) {
                GLES30.glDeleteTextures(1, intArrayOf(lutTextureId), 0)
                lutTextureId = 0
            }
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

            // 7. 映射 PBO 内存，读取像素（此时 GPU 传输已完成）
            val mappedBuf = GLES30.glMapBufferRange(
                GLES30.GL_PIXEL_PACK_BUFFER, 0, width * height * 4,
                GLES30.GL_MAP_READ_BIT
            ) as? ByteBuffer
            val outBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            if (mappedBuf != null) {
                mappedBuf.order(ByteOrder.nativeOrder())
                outBitmap.copyPixelsFromBuffer(mappedBuf)
                GLES30.glUnmapBuffer(GLES30.GL_PIXEL_PACK_BUFFER)
            } else {
                // 降级：PBO map 失败时回退到直接 glReadPixels
                Log.w(TAG, "PBO map failed, falling back to glReadPixels")
                val fallbackBuf = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
                GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
                GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, fallbackBuf)
                fallbackBuf.rewind()
                outBitmap.copyPixelsFromBuffer(fallbackBuf)
            }
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)

            val finalBitmap = maybeMirrorBitmap(outBitmap, mirrorOutput)
            if (finalBitmap !== outBitmap) {
                outBitmap.recycle()
            }

            // 8. 编码为 JPEG
            val outputFile = File(context.cacheDir, "gpu_${File(filePath).name}")
            val jpegQuality = ((params["jpegQuality"] as? Number)?.toInt() ?: 88).coerceIn(60, 95)
            FileOutputStream(outputFile).use { fos ->
                finalBitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, fos)
            }
            finalBitmap.recycle()

            Log.d(TAG, "GL GPU processing complete (PBO): ${outputFile.absolutePath}")
            outputFile.absolutePath

        } catch (e: Exception) {
            Log.e(TAG, "GL GPU processing failed", e)
            null
        }
    }

    /**
     * 内存模式：直接接受 JPEG 字节数组，跳过磁盘读取，减少一次文件 IO。
     * @param jpegBytes       原始 JPEG 字节（来自 OnImageCapturedCallback）
     * @param exifOrientation EXIF 旋转角度（0/90/180/270），由调用方从 ImageInfo 获取
     * @param isFrontCamera   是否前置摄像头（前置需水平镜像）
     * @param params          渲染参数（与 processImage 相同）
     * @return 处理后的 JPEG 文件路径，失败返回 null
     */
    fun processImageBytes(
        jpegBytes: ByteArray,
        exifOrientation: Int,
        isFrontCamera: Boolean,
        params: Map<String, Any>
    ): String? {
        return try {
            val mirrorOutput = (params["mirrorOutput"] as? Boolean) ?: isFrontCamera
            // 1. 解码内存 JPEG（跳过磁盘读取）
            val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
            val rawBitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size, options)
                ?: return null.also { Log.e(TAG, "Failed to decode JPEG bytes") }

            // 1a. 优先读取 JPEG 内存字节里的 EXIF Orientation（更可靠，避免方向猜测误差）。
            // 若内存字节无 EXIF（极少机型）再回退到 rotationDegrees + front 镜像。
            val exifTag = try {
                ExifInterface(ByteArrayInputStream(jpegBytes))
                    .getAttributeInt(
                        ExifInterface.TAG_ORIENTATION,
                        ExifInterface.ORIENTATION_UNDEFINED
                    )
            } catch (_: Exception) {
                ExifInterface.ORIENTATION_UNDEFINED
            }
            val exifBitmap = if (exifTag != ExifInterface.ORIENTATION_UNDEFINED &&
                exifTag != ExifInterface.ORIENTATION_NORMAL) {
                applyExifOrientation(rawBitmap, exifTag)
            } else {
                applyRotation(rawBitmap, exifOrientation, mirrorOutput)
            }
            if (exifBitmap !== rawBitmap) rawBitmap.recycle()

            // 1b. 按 maxDimension 缩放
            val maxDim = (params["maxDimension"] as? Int) ?: 4096
            val srcMax = maxOf(exifBitmap.width, exifBitmap.height)
            val inBitmap = if (srcMax > maxDim) {
                val scale = maxDim.toFloat() / srcMax
                val newW = (exifBitmap.width * scale).toInt()
                val newH = (exifBitmap.height * scale).toInt()
                Bitmap.createScaledBitmap(exifBitmap, newW, newH, true)
                    .also { exifBitmap.recycle() }
            } else {
                exifBitmap
            }
            val width = inBitmap.width
            val height = inBitmap.height

            // 2. 初始化 EGL + GL
            ensureGL(width, height)

            // 3. 上传输入图像为 GL 纹理
            val inputTex = uploadBitmapToTexture(inBitmap)
            inBitmap.recycle()

            // 4. 绑定 FBO，执行渲染
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
            GLES30.glViewport(0, 0, width, height)
            GLES30.glUseProgram(program)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTex)
            GLES30.glUniform1i(uInputTexture, 0)
            GLES30.glUniform2f(uTexelSize, 1.0f / width, 1.0f / height)
            setUniforms(params)
            val baseLutPath = params["baseLut"] as? String
            if (!baseLutPath.isNullOrEmpty()) {
                val lutTex = loadLutTexture(baseLutPath, context)
                if (lutTex != 0) {
                    lutTextureId = lutTex
                    GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
                    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, lutTex)
                    GLES30.glUniform1i(uLutTexture, 1)
                    GLES30.glUniform1f(uLutEnabled, 1.0f)
                }
            }
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
            val posLoc = GLES30.glGetAttribLocation(program, "aPosition")
            val uvLoc  = GLES30.glGetAttribLocation(program, "aTexCoord")
            GLES30.glEnableVertexAttribArray(posLoc)
            GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, 16, 0)
            GLES30.glEnableVertexAttribArray(uvLoc)
            GLES30.glVertexAttribPointer(uvLoc, 2, GLES30.GL_FLOAT, false, 16, 8)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
            GLES30.glFinish()

            // 5. PBO 异步回读
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pbo)
            GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, 0)

            // 6. 释放临时纹理（在 GPU 传输期间并行执行）
            GLES30.glDeleteTextures(1, intArrayOf(inputTex), 0)
            if (lutTextureId != 0) {
                GLES30.glDeleteTextures(1, intArrayOf(lutTextureId), 0)
                lutTextureId = 0
            }
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

            // 7. 映射 PBO 内存读取像素
            val mappedBuf = GLES30.glMapBufferRange(
                GLES30.GL_PIXEL_PACK_BUFFER, 0, width * height * 4,
                GLES30.GL_MAP_READ_BIT
            ) as? ByteBuffer
            val outBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            if (mappedBuf != null) {
                mappedBuf.order(ByteOrder.nativeOrder())
                outBitmap.copyPixelsFromBuffer(mappedBuf)
                GLES30.glUnmapBuffer(GLES30.GL_PIXEL_PACK_BUFFER)
            } else {
                Log.w(TAG, "PBO map failed (bytes path), falling back to glReadPixels")
                val fallbackBuf = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
                GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
                GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, fallbackBuf)
                fallbackBuf.rewind()
                outBitmap.copyPixelsFromBuffer(fallbackBuf)
            }
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)

            val finalBitmap = maybeMirrorBitmap(outBitmap, mirrorOutput)
            if (finalBitmap !== outBitmap) {
                outBitmap.recycle()
            }

            // 8. 编码为 JPEG
            val ts = System.currentTimeMillis()
            val outputFile = File(context.cacheDir, "gpu_mem_${ts}.jpg")
            val jpegQuality = ((params["jpegQuality"] as? Number)?.toInt() ?: 88).coerceIn(60, 95)
            FileOutputStream(outputFile).use { fos ->
                finalBitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, fos)
            }
            finalBitmap.recycle()
            Log.d(TAG, "processImageBytes complete (PBO): ${outputFile.absolutePath}")
            outputFile.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "processImageBytes failed", e)
            null
        }
    }

    /**
     * 根据旋转角度和镜像标志旋转 Bitmap（替代基于文件 EXIF 的 applyExifRotation）
     */
    private fun applyRotation(bitmap: Bitmap, rotationDegrees: Int, mirror: Boolean): Bitmap {
        val matrix = Matrix()
        if (rotationDegrees != 0) matrix.postRotate(rotationDegrees.toFloat())
        if (mirror) matrix.preScale(-1f, 1f)
        if (rotationDegrees == 0 && !mirror) return bitmap
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun maybeMirrorBitmap(bitmap: Bitmap, mirror: Boolean): Bitmap {
        if (!mirror) return bitmap
        val matrix = Matrix().apply { preScale(-1f, 1f) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    /**
     * 根据 EXIF Orientation 标记应用旋转/翻转。
     */
    private fun applyExifOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
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
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    fun destroy() {
        if (!initialized) return
        if (vbo != 0) GLES30.glDeleteBuffers(1, intArrayOf(vbo), 0)
        if (pbo != 0) GLES30.glDeleteBuffers(1, intArrayOf(pbo), 0)
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

        val pbufferAttribs = intArrayOf(
            EGL14.EGL_WIDTH, width,
            EGL14.EGL_HEIGHT, height,
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

        // 创建 PBO（Pixel Buffer Object）用于异步 glReadPixels，避免 GPU stall
        val pboArr = IntArray(1)
        GLES30.glGenBuffers(1, pboArr, 0)
        pbo = pboArr[0]
        GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pbo)
        GLES30.glBufferData(GLES30.GL_PIXEL_PACK_BUFFER, width * height * 4, null, GLES30.GL_STREAM_READ)
        GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
    }

    private fun rebuildFBO(width: Int, height: Int) {
        GLES30.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
        GLES30.glDeleteTextures(1, intArrayOf(renderTex), 0)
        if (pbo != 0) { GLES30.glDeleteBuffers(1, intArrayOf(pbo), 0); pbo = 0 }
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
        uGrainPatternStrength = loc("uGrainPatternStrength")
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
        uToneCurveCount = loc("uToneCurveCount")
        uToneCurveX = loc("uToneCurveX[0]")
        uToneCurveY = loc("uToneCurveY[0]")
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
        uGrainRoughness = loc("uGrainRoughness")
        uGrainLumaBias = loc("uGrainLumaBias")
        uGrainColorVariation = loc("uGrainColorVariation")
        uLuminanceNoise = loc("uLuminanceNoise")
        uChromaNoise = loc("uChromaNoise")
        uDehaze = loc("uDehaze")
        uHighlightWarmAmount = loc("uHighlightWarmAmount")
        uToneMapToe = loc("uToneMapToe")
        uToneMapShoulder = loc("uToneMapShoulder")
        uToneMapStrength = loc("uToneMapStrength")
        uMidGrayDensity = loc("uMidGrayDensity")
        uHighlightRolloffPivot = loc("uHighlightRolloffPivot")
        uHighlightRolloffSoftKnee = loc("uHighlightRolloffSoftKnee")
        uTopBottomBias = loc("uTopBottomBias")
        uLeftRightBias = loc("uLeftRightBias")
        uBwMixerEnabled = loc("uBwMixerEnabled")
        uBwChannelMixer = loc("uBwChannelMixer")
        uFadeAmount = loc("uFadeAmount")
        uShadowTint = loc("uShadowTint")
        uHighlightTint = loc("uHighlightTint")
        uSplitToneBalance = loc("uSplitToneBalance")
        uLightLeakAmount = loc("uLightLeakAmount")
        uLightLeakSeed = loc("uLightLeakSeed")
        uDustAmount = loc("uDustAmount")
        uScratchAmount = loc("uScratchAmount")
        uExposureOffset = loc("uExposureOffset")
        uFisheyeMode = loc("uFisheyeMode")
        uCircularFisheye = loc("uCircularFisheye")
        uAspectRatio = loc("uAspectRatio")
        uLensDistortion = loc("uLensDistortion")
        uLutTexture  = loc("uLutTexture")
        uLutEnabled  = loc("uLutEnabled")
        uLutStrength = loc("uLutStrength")
        uLutSize     = loc("uLutSize")
        uDeviceGamma = loc("uDeviceGamma")
        uDeviceWhiteScale = loc("uDeviceWhiteScale")
        uDeviceCcm = loc("uDeviceCcm")
    }

    private fun setUniforms(params: Map<String, Any>) {
        fun f(key: String, default: Float = 0.0f): Float = when (val v = params[key]) {
            is Double -> v.toFloat()
            is Float  -> v
            is Int    -> v.toFloat()
            is Long   -> v.toFloat()
            is String -> v.toFloatOrNull() ?: default
            else      -> default
        }
        fun listFloat(v: Any?): List<Float> {
            if (v !is List<*>) return emptyList()
            return v.mapNotNull {
                when (it) {
                    is Number -> it.toFloat()
                    is String -> it.toFloatOrNull()
                    else -> null
                }
            }
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
        GLES30.glUniform1f(uGrainPatternStrength, f("grain", 1.0f))
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
        GLES30.glUniform1f(uDehaze, f("dehaze"))
        GLES30.glUniform1f(uHighlightWarmAmount, f("highlightWarmAmount"))
        GLES30.glUniform1f(uToneMapToe, f("toneMapToe"))
        GLES30.glUniform1f(uToneMapShoulder, f("toneMapShoulder"))
        GLES30.glUniform1f(uToneMapStrength, f("toneMapStrength"))
        GLES30.glUniform1f(uMidGrayDensity, f("midGrayDensity"))
        GLES30.glUniform1f(uHighlightRolloffPivot, f("highlightRolloffPivot", 0.76f))
        GLES30.glUniform1f(uHighlightRolloffSoftKnee, f("highlightRolloffSoftKnee", 0.35f))
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
        GLES30.glUniform1f(uGrainRoughness, f("grainRoughness", 0.5f))
        GLES30.glUniform1f(uGrainLumaBias, f("grainLumaBias", 0.65f))
        GLES30.glUniform1f(uGrainColorVariation, f("grainColorVariation", 0.08f))
        GLES30.glUniform1f(uLuminanceNoise, f("luminanceNoise"))
        GLES30.glUniform1f(uChromaNoise, f("chromaNoise"))
        GLES30.glUniform1f(uTopBottomBias, f("topBottomBias"))
        GLES30.glUniform1f(uLeftRightBias, f("leftRightBias"))
        val bwMixer = listFloat(params["bwChannelMixer"])
        val hasBwMixer = bwMixer.size >= 3
        GLES30.glUniform1f(uBwMixerEnabled, if (hasBwMixer) 1.0f else 0.0f)
        GLES30.glUniform3f(
            uBwChannelMixer,
            if (hasBwMixer) bwMixer[0] else 0.2126f,
            if (hasBwMixer) bwMixer[1] else 0.7152f,
            if (hasBwMixer) bwMixer[2] else 0.0722f,
        )
        val tonePairs = mutableListOf<Pair<Float, Float>>()
        val rawToneCurve = params["toneCurvePoints"]
        if (rawToneCurve is List<*>) {
            for (point in rawToneCurve) {
                if (point !is List<*> || point.size < 2) continue
                val x = (point[0] as? Number)?.toFloat() ?: continue
                val y = (point[1] as? Number)?.toFloat() ?: continue
                tonePairs += Pair((x / 255.0f).coerceIn(0.0f, 1.0f), (y / 255.0f).coerceIn(0.0f, 1.0f))
            }
        }
        tonePairs.sortBy { it.first }
        val toneX = FloatArray(16)
        val toneY = FloatArray(16)
        val toneCount = tonePairs.size.coerceAtMost(16)
        if (toneCount >= 2) {
            for (i in 0 until toneCount) {
                toneX[i] = tonePairs[i].first
                toneY[i] = tonePairs[i].second
            }
            for (i in toneCount until 16) {
                toneX[i] = toneX[toneCount - 1]
                toneY[i] = toneY[toneCount - 1]
            }
        }
        GLES30.glUniform1i(uToneCurveCount, if (toneCount >= 2) toneCount else 0)
        GLES30.glUniform1fv(uToneCurveX, 16, toneX, 0)
        GLES30.glUniform1fv(uToneCurveY, 16, toneY, 0)
        GLES30.glUniform1f(uFadeAmount, f("fadeAmount"))
        GLES30.glUniform3f(uShadowTint, f("shadowTintR"), f("shadowTintG"), f("shadowTintB"))
        GLES30.glUniform3f(uHighlightTint, f("highlightTintR"), f("highlightTintG"), f("highlightTintB"))
        GLES30.glUniform1f(uSplitToneBalance, f("splitToneBalance", 0.5f))
        GLES30.glUniform1f(uLightLeakAmount, f("lightLeakAmount"))
        GLES30.glUniform1f(uLightLeakSeed, f("lightLeakSeed", System.currentTimeMillis().toFloat() / 1000.0f))
        GLES30.glUniform1f(uDustAmount, f("dustAmount"))
        GLES30.glUniform1f(uScratchAmount, f("scratchAmount"))
        GLES30.glUniform1f(uExposureOffset, f("exposureOffset"))
        GLES30.glUniform1f(uFisheyeMode, f("fisheyeMode"))
        GLES30.glUniform1f(uCircularFisheye, f("circularFisheye", f("fisheyeMode")))
        val lensDistortion = f("lensDistortion", f("distortion"))
        GLES30.glUniform1f(uLensDistortion, lensDistortion)
        // FIX: aspect must be min(w,h)/max(w,h) (<= 1.0) so fisheyeUV produces a round circle.
        // Capture images on Android are portrait (height > width), so w/h < 1.0 is already
        // correct, but we use min/max for safety (matches CameraGLRenderer and iOS MetalRenderer).
        val rawAr = if (f("aspectRatio") > 0.001f) f("aspectRatio")
                    else if (currentHeight > 0) currentWidth.toFloat() / currentHeight.toFloat()
                    else 1.0f
        val ar = if (rawAr > 1.0f) 1.0f / rawAr else rawAr  // ensure <= 1.0
        GLES30.glUniform1f(uAspectRatio, ar)
        GLES30.glUniform1f(uDeviceGamma, f("deviceGamma", 1.0f))
        GLES30.glUniform3f(
            uDeviceWhiteScale,
            f("deviceWhiteScaleR", 1.0f),
            f("deviceWhiteScaleG", 1.0f),
            f("deviceWhiteScaleB", 1.0f)
        )
        // GLSL mat3 uniform 采用列主序；toJson 传入为 row-major（00..22），这里做重排。
        val deviceCcmCols = floatArrayOf(
            f("deviceCcm00", 1.0f), f("deviceCcm10", 0.0f), f("deviceCcm20", 0.0f),
            f("deviceCcm01", 0.0f), f("deviceCcm11", 1.0f), f("deviceCcm21", 0.0f),
            f("deviceCcm02", 0.0f), f("deviceCcm12", 0.0f), f("deviceCcm22", 1.0f)
        )
        GLES30.glUniformMatrix3fv(uDeviceCcm, 1, false, deviceCcmCols, 0)
        // LUT uniform（纹理绑定在 processImage 中单独处理）
        GLES30.glUniform1f(uLutEnabled, 0.0f)  // 默认关闭，由 processImage 覆盖
        GLES30.glUniform1f(uLutStrength, f("lutStrength", 1.0f))
        GLES30.glUniform1f(uLutSize, 33.0f)
        Log.d(
            TAG,
            "capture.json ext dehaze=${f("dehaze")} warm=${f("highlightWarmAmount")} " +
                "tb=${f("topBottomBias")} lr=${f("leftRightBias")} " +
                "bw=${hasBwMixer} tonePts=${if (toneCount >= 2) toneCount else 0} " +
                "tmToe=${f("toneMapToe")} tmShoulder=${f("toneMapShoulder")} " +
                "tmStrength=${f("toneMapStrength")} midGray=${f("midGrayDensity")} " +
                "rolloffPivot=${f("highlightRolloffPivot", 0.76f)}"
        )
    }

    /**
     * 从 Flutter assets 中加载 .cube LUT 文件并上传为 GL 2D 纹理
     * LUT 布局：宽 = N*N，高 = N（与 iOS CaptureProcessor 完全一致）
     */
    private fun loadLutTexture(assetPath: String, context: android.content.Context): Int {
        return try {
            val inputStream = context.assets.open(assetPath.removePrefix("assets/"))
            val content = inputStream.bufferedReader().readText()
            inputStream.close()
            var lutSize = 33
            val dataValues = ArrayList<Float>(33 * 33 * 33 * 3)
            for (line in content.lines()) {
                val trimmed = line.trim()
                if (trimmed.startsWith("#") || trimmed.isEmpty()) continue
                if (trimmed.startsWith("LUT_3D_SIZE")) {
                    lutSize = trimmed.split("\\s+".toRegex()).lastOrNull()?.toIntOrNull() ?: 33
                    continue
                }
                if (trimmed.startsWith("TITLE") || trimmed.startsWith("DOMAIN")) continue
                val parts = trimmed.split("\\s+".toRegex())
                if (parts.size == 3) {
                    val r = parts[0].toFloatOrNull() ?: continue
                    val g = parts[1].toFloatOrNull() ?: continue
                    val b = parts[2].toFloatOrNull() ?: continue
                    dataValues.add(r); dataValues.add(g); dataValues.add(b)
                }
            }
            val expectedCount = lutSize * lutSize * lutSize
            if (dataValues.size != expectedCount * 3) {
                Log.e(TAG, "LUT data count mismatch: ${dataValues.size / 3} vs $expectedCount")
                return 0
            }
            // 将 3D LUT 转换为 2D 纹理（宽 = N*N，高 = N）
            val texW = lutSize * lutSize
            val texH = lutSize
            val rgba = ByteArray(texW * texH * 4)
            for (i in 0 until (lutSize * lutSize * lutSize)) {
                rgba[i * 4 + 0] = (dataValues[i * 3 + 0].coerceIn(0f, 1f) * 255f + 0.5f).toInt().toByte()
                rgba[i * 4 + 1] = (dataValues[i * 3 + 1].coerceIn(0f, 1f) * 255f + 0.5f).toInt().toByte()
                rgba[i * 4 + 2] = (dataValues[i * 3 + 2].coerceIn(0f, 1f) * 255f + 0.5f).toInt().toByte()
                rgba[i * 4 + 3] = 255.toByte()
            }
            val texArr = IntArray(1)
            GLES30.glGenTextures(1, texArr, 0)
            val tex = texArr[0]
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            val buf = java.nio.ByteBuffer.wrap(rgba)
            GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA, texW, texH, 0,
                                GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf)
            Log.d(TAG, "LUT loaded: $assetPath (${lutSize}^3)")
            tex
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load LUT: $assetPath", e)
            0
        }
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
