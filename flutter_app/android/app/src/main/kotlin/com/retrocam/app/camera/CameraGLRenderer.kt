package com.retrocam.app.camera

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import android.content.Context
import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * CameraGLRenderer — 两步渲染架构
 *
 * 渲染链（修复 OES 纹理多次采样导致的动态斜纹）：
 *   CameraX Preview → inputSurfaceTexture (GL_TEXTURE_EXTERNAL_OES)
 *     → Pass 1: 直通 Shader 将 OES 拷贝到 FBO (GL_TEXTURE_2D)
 *     → Pass 2: 效果 Shader 从稳定的 GL_TEXTURE_2D 采样（20 Pass 渲染）
 *     → eglSwapBuffers → Flutter SurfaceTexture（Window Surface）
 *
 * 根因：GL_TEXTURE_EXTERNAL_OES 在 tile-based GPU（Mali/Adreno）上
 * 不保证同一帧内多次采样的一致性，当 Shader 对 OES 纹理采样 25+ 次时
 * （锐化 9 + CA 3 + Clarity 9 + 柔化 4），会出现帧间数据不一致导致的彩色斜纹。
 * 解决方案：先将 OES 拷贝到普通 2D 纹理，再从 2D 纹理做所有效果处理。
 */
class CameraGLRenderer(
    private val flutterSurfaceTexture: SurfaceTexture,
    context: Context? = null
) {
    private val contextRef: WeakReference<Context>? = context?.let { WeakReference(it) }
    companion object {
        private const val TAG = "CameraGLRenderer"

        // ── 顶点着色器（两个 Pass 共用）──────────────────────────────────────
        private const val VERTEX_SHADER = """#version 300 es
in vec4 aPosition;
in vec2 aTexCoord;
out vec2 vTexCoord;
uniform mat4 uSTMatrix;
void main() {
    gl_Position = aPosition;
    vTexCoord = (uSTMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
}"""

        // ── 顶点着色器（Pass 2 效果处理，不需要 ST 矩阵变换）──────────────────
        private const val VERTEX_SHADER_PASS2 = """#version 300 es
in vec4 aPosition;
in vec2 aTexCoord;
out vec2 vTexCoord;
void main() {
    gl_Position = aPosition;
    vTexCoord = aTexCoord;
}"""

        // ── Pass 1: OES → 2D 直通 Shader ────────────────────────────────────
        // 仅做一次采样，将 OES 纹理内容拷贝到 FBO 上的普通 2D 纹理
        private const val COPY_FRAGMENT_SHADER = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
in  vec2 vTexCoord;
out vec4 fragColor;
uniform samplerExternalOES uCameraTexture;
void main() {
    fragColor = texture(uCameraTexture, vTexCoord);
}"""

        // ── Pass 2: 效果处理 Shader（从普通 sampler2D 采样）──────────────────
        // 关键变化：uInputTexture 是 sampler2D 而非 samplerExternalOES
        // 这保证了所有采样都来自同一帧的稳定数据
        private const val FRAGMENT_SHADER = """#version 300 es
precision highp float;

in  vec2 vTexCoord;
out vec4 fragColor;

uniform sampler2D uInputTexture;

// CCD 参数
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift;
uniform float uChromaticAberration;
uniform float uNoiseAmount;
uniform float uVignetteAmount;
uniform float uGrainAmount;
uniform float uSharpen;
uniform float uTime;
uniform vec2  uTexelSize;   // 1/width, 1/height
uniform float uFisheyeMode; // 1.0=圆形鱼眼模式, 0.0=普通模式
uniform float uAspectRatio; // 宽/高 比例（用于保持圆形）
uniform float uLensDistortion; // 轻量桶形畸变（非圆形鱼眼）
uniform float uMirrorX; // 1.0=水平镜像, 0.0=不镜像
// ── 传感器非均匀性（数码相机通用，FXN-R 专项调校）──
uniform float uCenterGain;          // 中心增亮（FXN-R=0.010）
uniform float uEdgeFalloff;         // 边缘衰减（FXN-R=0.035）
uniform float uExposureVariation;   // 曝光波动（FXN-R=0.020）
uniform float uCornerWarmShift;     // 角落色温偏移（FXN-R=-0.015，负=偏冷青）
uniform float uDevelopmentSoftness; // 显影柔化（FXN-R=0.020）
uniform float uChemicalIrregularity;// 化学不规则感（FXN-R=0.010）
// ── 肤色保护（冷色调相机必须开启，防止肤色发青）──
uniform float uSkinHueProtect;      // 肤色色相保护（1.0=开启）
uniform float uSkinSatProtect;      // 肤色饱和度保护（FXN-R=0.96）
uniform float uSkinLumaSoften;      // 肤色亮度柔化（FXN-R=0.030）
uniform float uSkinRedLimit;        // 肤色红限（FXN-R=1.04）
// ── 噪声分离──
uniform float uLuminanceNoise;      // 亮度噪声（FXN-R=0.02）
uniform float uChromaNoise;         // 色度噪声（FXN-R=0.01）
// ── LUT + Tone Curve + Highlight Rolloff ──
uniform float uHighlightRolloff2;   // 高光柔和滚落（FXN-R=0.16）
uniform float uToneCurveStrength;   // Tone Curve 强度（FXN-R=1.0）
// ── Lightroom 风格参数（Phase 2 下沉：原 Flutter ColorFilter 矩阵逻辑）──
uniform float uHighlights;          // 高光调整 (-200~+200)
uniform float uShadows;             // 阴影调整 (-200~+200)
uniform float uWhites;              // 白场 (-200~+200)
uniform float uBlacks;              // 黑场 (-200~+200)
uniform float uClarity;             // 清晰度 (-200~+200)
uniform float uVibrance;            // 自然饱和度 (-200~+200)
// ── RGB 通道偏移 + Tint ──
uniform float uColorBiasR;          // R 通道偏移（如 CCD R: +0.048）
uniform float uColorBiasG;          // G 通道偏移（如 CCD R: -0.008）
uniform float uColorBiasB;          // B 通道偏移（如 CCD R: -0.030）
uniform float uTintShift;           // 色调偏移（绿-品红轴）
// ── 光学特效（Phase 2 下沉：原 Flutter Widget 层 Bloom/Halation）──
uniform float uHalationAmount;      // 高光辉光（如 FQS: 0.12）
uniform float uBloomAmount;         // 高光光晕（如 CPM35: 0.15）
uniform float uGrainSize;           // 颗粒大小（如 FQS: 1.2）
uniform float uHighlightRolloff;    // 高光滚落（预览用，如 INST C: 0.18）
uniform float uPaperTexture;        // 相纸纹理（如 INST C: 0.15）
// ── Fade（褒色）+ Split Toning（分离色调）──
uniform float uFadeAmount;           // 褒色强度（0.0~0.3，提升黑场为深灰）
uniform vec3  uShadowTint;           // 阴影色调（如 vec3(0.1, 0.1, 0.2) 偏蓝）
uniform vec3  uHighlightTint;        // 高光色调（如 vec3(0.2, 0.15, 0.05) 偏暖）
uniform float uSplitToneBalance;     // 分离色调平衡（0.0=偏阴影，1.0=偏高光，默认0.5）
// ── Light Leak（GPU 漏光）──
uniform float uLightLeakAmount;      // 漏光强度（0.0~1.0）
uniform float uLightLeakSeed;        // 漏光随机种子（每次拍照随机变化）
uniform float uExposureOffset;        // 用户曝光补偿（-2.0~+2.0）
// ── #1 LUT Pass（预览与成片色彩一致）──
uniform sampler2D uLutTexture;        // LUT 2D 纹理（N*N × N，B-fastest 排列）
uniform float     uLutEnabled;        // 1.0 = 启用 LUT
uniform float     uLutStrength;       // LUT 混合强度（0.0~1.0）
uniform float     uLutSize;           // LUT 边长（通常 33.0）
// ── Device Calibration（V3：设备级线性校准）──
uniform float uDeviceGamma;
uniform vec3  uDeviceWhiteScale;
uniform mat3  uDeviceCcm;

// ── 工具函数 ──────────────────────────────────────────────────────────────────
// #1 LUT 采样（2D 纹理模拟 3D LUT，B-fastest 排列）
vec3 previewSampleLUT(vec3 color, sampler2D lut, float lutSize) {
    float bIdx = floor(color.b * (lutSize - 1.0) + 0.5);
    float u = (bIdx * lutSize + color.r * (lutSize - 1.0) + 0.5) / (lutSize * lutSize);
    float v = (color.g * (lutSize - 1.0) + 0.5) / lutSize;
    return texture(lut, vec2(u, v)).rgb;
}
// 高光柔和滚落
vec3 ccdHighlightRolloff(vec3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.3;
    return clamp(color * compress, 0.0, 1.0);
}
// FXN-R Tone Curve（分段线性插値）
float fxnrToneCurve(float x) {
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
float random(vec2 st, float seed) {
    return fract(sin(dot(st + seed, vec2(12.9898, 78.233))) * 43758.5453);
}

vec3 applyContrast(vec3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

vec3 applySaturation(vec3 c, float sat) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return mix(vec3(lum), c, sat);
}

vec3 applyTemperature(vec3 c, float shift) {
    float s = shift / 1000.0;
    c.r = clamp(c.r + s * 0.3, 0.0, 1.0);
    c.b = clamp(c.b - s * 0.3, 0.0, 1.0);
    return c;
}

float vignetteEffect(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    float dist = length(d) * 2.0;
    return 1.0 - smoothstep(1.0 - amount, 1.5, dist) * amount;
}

// Unsharp Mask: 3x3 高斯模糊 + 差值增强
vec3 applySharpen(vec2 uv, float amount) {
    vec3 center = texture(uInputTexture, uv).rgb;
    if (amount <= 0.0) return center;

    vec3 blur =
        texture(uInputTexture, uv + vec2(-uTexelSize.x, -uTexelSize.y)).rgb * 1.0 +
        texture(uInputTexture, uv + vec2( 0.0,          -uTexelSize.y)).rgb * 2.0 +
        texture(uInputTexture, uv + vec2( uTexelSize.x, -uTexelSize.y)).rgb * 1.0 +
        texture(uInputTexture, uv + vec2(-uTexelSize.x,  0.0         )).rgb * 2.0 +
        center                                                                * 4.0 +
        texture(uInputTexture, uv + vec2( uTexelSize.x,  0.0         )).rgb * 2.0 +
        texture(uInputTexture, uv + vec2(-uTexelSize.x,  uTexelSize.y)).rgb * 1.0 +
        texture(uInputTexture, uv + vec2( 0.0,           uTexelSize.y)).rgb * 2.0 +
        texture(uInputTexture, uv + vec2( uTexelSize.x,  uTexelSize.y)).rgb * 1.0;
    blur /= 16.0;

    float strength = amount * 2.0;
    return clamp(center + strength * (center - blur), 0.0, 1.0);
}

// ── 传感器非均匀性工具函数 ──────────────────────────────────────────────
float ccdCenterEdge(vec2 uv, float centerGain, float edgeFalloff) {
    vec2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}
vec3 ccdCornerWarm(vec2 uv, vec3 color, float shift) {
    vec2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor;
    color.r = clamp(color.r + s * 0.4, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.4, 0.0, 1.0);
    return color;
}
vec3 ccdDevelopmentSoften(vec2 uv, vec3 color, float softness) {
    if (softness <= 0.0) return color;
    vec3 blurred =
        texture(uInputTexture, uv + vec2(-uTexelSize.x, 0.0)).rgb * 0.25 +
        texture(uInputTexture, uv + vec2( uTexelSize.x, 0.0)).rgb * 0.25 +
        texture(uInputTexture, uv + vec2(0.0, -uTexelSize.y)).rgb * 0.25 +
        texture(uInputTexture, uv + vec2(0.0,  uTexelSize.y)).rgb * 0.25;
    return mix(color, blurred, softness * 0.5);
}
vec3 ccdRgbToHsl(vec3 rgb) {
    float maxC = max(max(rgb.r, rgb.g), rgb.b);
    float minC = min(min(rgb.r, rgb.g), rgb.b);
    float delta = maxC - minC;
    float l = (maxC + minC) * 0.5;
    float s = (delta < 0.001) ? 0.0 : delta / (1.0 - abs(2.0 * l - 1.0));
    float h = 0.0;
    if (delta > 0.001) {
        if (maxC == rgb.r)      h = mod((rgb.g - rgb.b) / delta, 6.0);
        else if (maxC == rgb.g) h = (rgb.b - rgb.r) / delta + 2.0;
        else                    h = (rgb.r - rgb.g) / delta + 4.0;
        h = h / 6.0;
        if (h < 0.0) h += 1.0;
    }
    return vec3(h, s, l);
}
vec3 ccdSkinProtect(vec3 color, float protect, float satProt, float lumaSoften, float redLimit) {
    if (protect < 0.5) return color;
    vec3 hsl = ccdRgbToHsl(color);
    float hue = hsl.x;
    float skinMask = smoothstep(0.0356, 0.0756, hue) * (1.0 - smoothstep(0.105, 0.145, hue));
    if (skinMask < 0.001) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    vec3 prot = mix(vec3(luma), color, satProt);
    prot = clamp(prot + lumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, redLimit);
    return mix(color, prot, skinMask);
}
// ── 圆形鱼眼投影 ──────────────────────────────────────────────────
vec2 fisheyeUV(vec2 uv, float aspect) {
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r = length(p);
    // 缩小有效圆半径，让鱼眼“圆边界”更明显（视觉更接近主流鱼眼相机）。
    const float rMax = 0.98;
    if (r > rMax) return vec2(-1.0);
    float rn = r / rMax;
    float theta = rn * 1.5707963; // pi/2
    float phi = atan(p.y, p.x);
    float sinTheta = sin(theta);
    vec2 texCoord = vec2(
        sinTheta * cos(phi),
        sinTheta * sin(phi)
    );
    texCoord = texCoord * 0.5 + 0.5;
    return texCoord;
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

// ── Phase 2 下沉工具函数：Blacks/Whites、Highlights/Shadows、Clarity、Vibrance、
//    ColorBias、Tint、Bloom、Halation、PaperTexture、HighlightRolloff ──
vec3 applyBlacksWhites(vec3 c, float blacks, float whites) {
    float b = blacks / 200.0;
    float w = whites / 200.0;
    c = c * (1.0 + w - b) + b;
    return clamp(c, 0.0, 1.0);
}
vec3 applyHighlightsShadows(vec3 c, float highlights, float shadows) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float h = highlights / 200.0;
    float s = shadows / 200.0;
    float highlightMask = smoothstep(0.5, 1.0, lum);
    float shadowMask    = 1.0 - smoothstep(0.0, 0.5, lum);
    c = c + c * h * highlightMask - c * h * highlightMask * highlightMask;
    c = c + (1.0 - c) * s * shadowMask;
    return clamp(c, 0.0, 1.0);
}
vec3 applyClarity(vec3 c, vec2 uv, float clarity) {
    if (abs(clarity) < 0.5) return c;
    vec3 blurred = vec3(0.0);
    float w = uTexelSize.x * 3.0;
    float h = uTexelSize.y * 3.0;
    blurred += texture(uInputTexture, uv + vec2(-w, -h)).rgb * 0.0625;
    blurred += texture(uInputTexture, uv + vec2( 0, -h)).rgb * 0.125;
    blurred += texture(uInputTexture, uv + vec2( w, -h)).rgb * 0.0625;
    blurred += texture(uInputTexture, uv + vec2(-w,  0)).rgb * 0.125;
    blurred += texture(uInputTexture, uv + vec2( 0,  0)).rgb * 0.25;
    blurred += texture(uInputTexture, uv + vec2( w,  0)).rgb * 0.125;
    blurred += texture(uInputTexture, uv + vec2(-w,  h)).rgb * 0.0625;
    blurred += texture(uInputTexture, uv + vec2( 0,  h)).rgb * 0.125;
    blurred += texture(uInputTexture, uv + vec2( w,  h)).rgb * 0.0625;
    float midMask = 1.0 - abs(dot(c, vec3(0.2126, 0.7152, 0.0722)) * 2.0 - 1.0);
    vec3 detail = c - blurred;
    return clamp(c + detail * clarity * 0.003 * midMask, 0.0, 1.0);
}
vec3 applyVibrance(vec3 c, float vibrance) {
    if (abs(vibrance) < 0.5) return c;
    float v = vibrance / 100.0;
    float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    float mask = 1.0 - sat;
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(lum), c, 1.0 + v * mask), 0.0, 1.0);
}
vec3 applyTint(vec3 c, float shift) {
    float s = shift / 1000.0;
    c.g = clamp(c.g + s * 0.2, 0.0, 1.0);
    return c;
}
vec3 applyColorBias(vec3 c, float r, float g, float b) {
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
vec3 applyBloom(vec3 c, float amount, vec2 uv) {
    if (amount < 0.001) return c;
    // 采样周围像素的高光区域，模拟光线向周围扩散
    float bloomRadius = amount * 12.0;
    vec3 bloomColor = vec3(0.0);
    float totalWeight = 0.0;
    // 9 点采样（十字形 + 对角线）模拟高斯扩散
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            vec2 offset = vec2(float(i), float(j)) * uTexelSize * bloomRadius;
            vec3 sample_c = texture(uInputTexture, uv + offset).rgb;
            float sLum = dot(sample_c, vec3(0.2126, 0.7152, 0.0722));
            // 只提取高光区域（亮度 > 0.7）
            float highlight = clamp((sLum - 0.7) / 0.3, 0.0, 1.0);
            float w = (i == 0 && j == 0) ? 4.0 : (abs(i) + abs(j) == 1 ? 2.0 : 1.0);
            bloomColor += sample_c * highlight * w;
            totalWeight += w;
        }
    }
    bloomColor /= totalWeight;
    // 添加暖色偏移（模拟镜头内部反射的暖色色散）
    bloomColor *= vec3(1.0, 0.9, 0.7);
    c = clamp(c + bloomColor * amount * 1.5, 0.0, 1.0);
    return c;
}
vec3 applyHalation(vec3 c, float amount, vec2 uv) {
    if (amount < 0.001) return c;
    // Halation：光线穿透胶片乳剂层后在背板反射，产生红橙色光晕
    // 采样更大范围（模拟胶片内部散射距离更远）
    float haloRadius = amount * 18.0;
    vec3 haloColor = vec3(0.0);
    float totalWeight = 0.0;
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            if (abs(i) + abs(j) > 3) continue; // 跳过角落，保持圆形
            vec2 offset = vec2(float(i), float(j)) * uTexelSize * haloRadius;
            vec3 sample_c = texture(uInputTexture, uv + offset).rgb;
            float sLum = dot(sample_c, vec3(0.2126, 0.7152, 0.0722));
            float highlight = clamp((sLum - 0.6) / 0.4, 0.0, 1.0);
            float dist = float(abs(i) + abs(j));
            float w = 1.0 / (1.0 + dist);
            haloColor += sample_c * highlight * w;
            totalWeight += w;
        }
    }
    haloColor /= totalWeight;
    // Halation 特征色：红橙色（R 通道最强，G 较弱，B 最弱）
    float haloLum = dot(haloColor, vec3(0.2126, 0.7152, 0.0722));
    c.r = clamp(c.r + haloLum * amount * 1.2, 0.0, 1.0);
    c.g = clamp(c.g + haloLum * amount * 0.35, 0.0, 1.0);
    c.b = clamp(c.b + haloLum * amount * 0.05, 0.0, 1.0);
    return c;
}
vec3 applyPaperTexture(vec3 c, vec2 uv, float amount) {
    if (amount < 0.001) return c;
    float n = random(uv * 50.0, 0.0) - 0.5;
    return clamp(c + n * amount * 0.04, 0.0, 1.0);
}
vec3 applyHighlightRolloffPreview(vec3 c, float rolloff) {
    if (rolloff < 0.001) return c;
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    if (lum > 0.70) {
        float t = (lum - 0.70) / 0.30;
        float compress = 1.0 - t * t * (3.0 - 2.0 * t) * rolloff * 0.3;
        c *= compress;
    }
    return clamp(c, 0.0, 1.0);
}

// ── Fade（褒色）──────────────────────────────────────────────────────────────
vec3 applyFade(vec3 c, float amount) {
    if (amount < 0.001) return c;
    // 提升黑场：纯黑变为深灰，模拟老胶片的低对比度感
    c = c * (1.0 - amount) + amount;
    // 同时轻微压缩高光，避免过曝
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float hlCompress = smoothstep(0.8, 1.0, lum) * amount * 0.3;
    c = c - hlCompress;
    return clamp(c, 0.0, 1.0);
}
// ── Split Toning（分离色调）──────────────────────────────────────────────────────
vec3 applySplitTone(vec3 c, vec3 shadowTint, vec3 highlightTint, float balance) {
    if (length(shadowTint) + length(highlightTint) < 0.001) return c;
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    // 阴影区域着色（亮度低于平衡点）
    float shadowMask = 1.0 - smoothstep(0.0, balance, lum);
    // 高光区域着色（亮度高于平衡点）
    float highlightMask = smoothstep(balance, 1.0, lum);
    c = c + shadowTint * shadowMask + highlightTint * highlightMask;
    return clamp(c, 0.0, 1.0);
}
// ── Light Leak（GPU 漏光）────────────────────────────────────────────────────────
vec3 applyLightLeak(vec3 c, vec2 uv, float amount, float seed) {
    if (amount < 0.001) return c;
    // 使用低频噪声生成随机漏光位置和颜色
    float angle = random(vec2(seed, seed * 0.7), 0.0) * 6.2832; // 随机角度
    vec2 leakCenter = vec2(
        0.5 + cos(angle) * 0.5, // 漏光中心在边缘
        0.5 + sin(angle) * 0.5
    );
    float dist = length(uv - leakCenter);
    float leak = smoothstep(0.8, 0.0, dist) * amount;
    // 漏光颜色：随机的暖色色调（橙红~金黄）
    float hue = random(vec2(seed * 1.3, seed * 2.1), 0.0);
    vec3 leakColor = mix(
        vec3(1.0, 0.4, 0.1),  // 橙红
        vec3(1.0, 0.8, 0.2),  // 金黄
        hue
    );
    // 以 Screen 混合模式叠加（保持高光不过曝）
    vec3 leaked = 1.0 - (1.0 - c) * (1.0 - leakColor * leak);
    return clamp(leaked, 0.0, 1.0);
}

// ── 主函数（统一渲染管线，所有相机差异由 uniform 参数驱动）────────────
void main() {
    vec2 uv = vTexCoord;
    if (uMirrorX > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    // 鱼眼模式：重映射 UV 坐标
    if (uFisheyeMode > 0.5) {
        vec2 fUV = fisheyeUV(uv, uAspectRatio);
        if (fUV.x < 0.0) {
            fragColor = vec4(0.0, 0.0, 0.0, 1.0);
            return;
        }
        uv = fUV;
    } else if (abs(uLensDistortion) > 0.0001) {
        uv = clamp(barrelDistortUV(uv, uLensDistortion, uAspectRatio), vec2(0.0), vec2(1.0));
    }

    // Pass 0: 锐化 (Unsharp Mask)
    vec3 color = applySharpen(uv, uSharpen);

    // Pass 1: 色差 (Chromatic Aberration)
    if (uChromaticAberration > 0.0) {
        float ca = uChromaticAberration * uTexelSize.x * 20.0;
        float r = texture(uInputTexture, uv + vec2(ca, 0.0)).r;
        float g = texture(uInputTexture, uv).g;
        float b = texture(uInputTexture, uv - vec2(ca, 0.0)).b;
        color = vec3(r, g, b);
    }

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

    // Pass 3: 黑场/白场
    color = applyBlacksWhites(color, uBlacks, uWhites);

    // Pass 4: 高光/阴影
    color = applyHighlightsShadows(color, uHighlights, uShadows);

    // Pass 5: 对比度
    color = applyContrast(color, uContrast);

    // Pass 6: Clarity
    color = applyClarity(color, uv, uClarity);

    // Pass 7: 饱和度 + Vibrance
    color = applySaturation(color, uSaturation);
    color = applyVibrance(color, uVibrance);

    // Pass 8: RGB 通道偏移
    color = applyColorBias(color, uColorBiasR, uColorBiasG, uColorBiasB);

    // Pass 9: Bloom（空间扩散光晕）
    color = applyBloom(color, uBloomAmount, uv);

    // Pass 10: Halation（红橙色胶片辉光）
    color = applyHalation(color, uHalationAmount, uv);

    // Pass 11: Highlight Rolloff
    color = applyHighlightRolloffPreview(color, uHighlightRolloff);

    // Pass 12: 传感器非均匀性
    if (uCenterGain > 0.0 || uEdgeFalloff > 0.0) {
        float factor = ccdCenterEdge(uv, uCenterGain, uEdgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    if (uExposureVariation > 0.0) {
        float evn = random(uv * 0.1, uTime * 0.01) - 0.5;
        color = clamp(color + evn * uExposureVariation * 0.3, 0.0, 1.0);
    }
    if (uCornerWarmShift != 0.0) {
        color = ccdCornerWarm(uv, color, uCornerWarmShift);
    }

    // Pass 13: 肤色保护
    color = ccdSkinProtect(color, uSkinHueProtect, uSkinSatProtect, uSkinLumaSoften, uSkinRedLimit);

    // Pass 14: 显影柔化
    if (uDevelopmentSoftness > 0.0) {
        color = ccdDevelopmentSoften(uv, color, uDevelopmentSoftness);
    }

    // Pass 15: 高光柔和滚落 2（Tone Curve 配合）
    if (uHighlightRolloff2 > 0.0) {
        color = ccdHighlightRolloff(color, uHighlightRolloff2);
    }

    // Pass 16: Tone Curve
    if (uToneCurveStrength > 0.0) {
        vec3 curved = vec3(
            fxnrToneCurve(color.r),
            fxnrToneCurve(color.g),
            fxnrToneCurve(color.b)
        );
        color = mix(color, curved, uToneCurveStrength);
    }

    // Pass 17: 相纸纹理
    color = applyPaperTexture(color, uv, uPaperTexture);

    // Pass 18: 胶片颗粒（亮度依赖 + grainSize 控制）
    if (uGrainAmount > 0.0) {
        // 使用 grainSize 缩放 UV，控制颗粒大小（值越大颗粒越粗）
        vec2 grainUV = uv / max(uGrainSize * uTexelSize * 800.0, vec2(0.001));
        float timeSeed = floor(uTime * 24.0) / 24.0;
        // 多层噪声叠加：模拟银盐晶体的自然随机分布
        float grain = random(grainUV, timeSeed) - 0.5;
        grain += (random(grainUV * 1.7, timeSeed + 1.0) - 0.5) * 0.5;
        grain *= 0.667; // 归一化
        // 亮度依赖掩码：中间调颗粒最强，纯黑/纯白区域平滑
        float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float lumMask = 1.0 - pow(abs(lum * 2.0 - 1.0), 2.0); // 抛物线：0→0, 0.5→1, 1→0
        lumMask = mix(0.3, 1.0, lumMask); // 保留最低 30% 强度，避免完全无颗粒
        color = clamp(color + grain * uGrainAmount * 0.25 * lumMask, 0.0, 1.0);
    }

    // Pass 19: 数字噪点
    if (uNoiseAmount > 0.0) {
        float lum   = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float noise = random(uv, uTime) - 0.5;
        float dark  = 1.0 - lum;
        color = clamp(color + noise * uNoiseAmount * 0.2 * dark, 0.0, 1.0);
    }
    if (uLuminanceNoise > 0.0) {
        float ln = random(uv, uTime + 1.7) - 0.5;
        color = clamp(color + ln * uLuminanceNoise * 0.15, 0.0, 1.0);
    }
    if (uChromaNoise > 0.0) {
        float cr = random(uv, uTime + 3.1) - 0.5;
        float cg = random(uv, uTime + 5.3) - 0.5;
        float cb = random(uv, uTime + 7.7) - 0.5;
        color = clamp(color + vec3(cr, cg, cb) * uChromaNoise * 0.08, 0.0, 1.0);
    }

    // Pass 20: Fade（褒色）
    color = applyFade(color, uFadeAmount);

    // Pass 21: Split Toning（分离色调）
    color = applySplitTone(color, uShadowTint, uHighlightTint, uSplitToneBalance);

    // Pass 22: Light Leak（GPU 漏光）
    color = applyLightLeak(color, uv, uLightLeakAmount, uLightLeakSeed);

    // Pass 23: 暗角（鱼眼模式下不叠加额外暗角）
    if (uFisheyeMode < 0.5) {
        float vignette = vignetteEffect(uv, uVignetteAmount);
        color *= vignette;
    }
    // Pass 24: #1 LUT 色彩映射（与成片管线一致）
    if (uLutEnabled > 0.5) {
        vec3 lutColor = previewSampleLUT(clamp(color, 0.0, 1.0), uLutTexture, uLutSize);
        color = mix(color, lutColor, uLutStrength);
    }
    fragColor = vec4(color, 1.0);
}"""

        // 全屏四边形顶点（位置 + UV）
        private val QUAD_VERTICES = floatArrayOf(
            -1f,  1f,  0f, 1f,   // 左上  → UV(0,1)
            -1f, -1f,  0f, 0f,   // 左下  → UV(0,0)
             1f,  1f,  1f, 1f,   // 右上  → UV(1,1)
             1f, -1f,  1f, 0f    // 右下  → UV(1,0)
        )
    }

    // ── EGL ─────────────────────────────────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // ── GL 资源 ──────────────────────────────────────────────────────────────
    // Pass 1: OES → FBO 直通
    private var copyProgramId: Int = 0
    private var copyUCameraTexture: Int = -1
    private var copyUSTMatrix: Int = -1
    private var copyAPositionLoc: Int = -1
    private var copyATexCoordLoc: Int = -1

    // FBO（中间 2D 纹理）
    private var fboId: Int = 0
    private var fboTexId: Int = 0

    // Pass 2: 效果处理
    private var programId: Int = 0
    private var cameraTexId: Int = 0
    private var vertexBuffer: FloatBuffer? = null

    // Pass 2 Uniform 位置
    private var uInputTexture: Int = -1
    private var uContrast: Int = -1
    private var uSaturation: Int = -1
    private var uTemperatureShift: Int = -1
    private var uChromaticAberration: Int = -1
    private var uNoiseAmount: Int = -1
    private var uVignetteAmount: Int = -1
    private var uGrainAmount: Int = -1
    private var uSharpen: Int = -1
    private var uTime: Int = -1
    private var uTexelSize: Int = -1
    private var uFisheyeMode: Int = -1
    private var uAspectRatio: Int = -1
    private var uLensDistortion: Int = -1
    private var uMirrorX: Int = -1
    private var uHighlights: Int = -1
    private var uShadows: Int = -1
    private var uWhites: Int = -1
    private var uBlacks: Int = -1
    private var uClarity: Int = -1
    private var uVibrance: Int = -1
    private var uColorBiasR: Int = -1
    private var uColorBiasG: Int = -1
    private var uColorBiasB: Int = -1
    private var uTintShift: Int = -1
    private var uHalationAmount: Int = -1
    private var uBloomAmount: Int = -1
    private var uGrainSize: Int = -1
    private var uLuminanceNoise: Int = -1
    private var uChromaNoise: Int = -1
    private var uHighlightRolloff: Int = -1
    private var uPaperTexture: Int = -1
    private var uEdgeFalloff: Int = -1
    private var uExposureVariation: Int = -1
    private var uCornerWarmShift: Int = -1
    private var uCenterGain: Int = -1
    private var uDevelopmentSoftness: Int = -1
    private var uChemicalIrregularity: Int = -1
    private var uSkinHueProtect: Int = -1
    private var uSkinSatProtect: Int = -1
    private var uSkinLumaSoften: Int = -1
    private var uSkinRedLimit: Int = -1
    private var uHighlightRolloff2: Int = -1
    private var uToneCurveStrength: Int = -1
    private var uFadeAmount: Int = -1
    private var uShadowTint: Int = -1
    private var uHighlightTint: Int = -1
    private var uSplitToneBalance: Int = -1
    private var uLightLeakAmount: Int = -1
    private var uLightLeakSeed: Int = -1
     private var uExposureOffset: Int = -1
    // #1 LUT uniform 位置
    private var uLutTexture: Int = -1
    private var uLutEnabled: Int = -1
    private var uLutStrength: Int = -1
    private var uLutSize: Int = -1
    private var uDeviceGamma: Int = -1
    private var uDeviceWhiteScale: Int = -1
    private var uDeviceCcm: Int = -1
    // Pass 2 Attrib 位置
    private var aPositionLoc: Int = -1
    private var aTexCoordLoc: Int = -1

    // SurfaceTexture 变换矩阵
    private val stMatrix = FloatArray(16)
    // 单位矩阵（Pass 2 不需要 ST 变换）
    private val identityMatrix = floatArrayOf(
        1f, 0f, 0f, 0f,
        0f, 1f, 0f, 0f,
        0f, 0f, 1f, 0f,
        0f, 0f, 0f, 1f
    )

    // ── 相机输入 SurfaceTexture ──────────────────────────────────────────────
    private var inputSurfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null
    @Volatile private var currentCameraId: String = ""
    @Volatile private var pendingCameraId: String = ""

    // ── 渲染参数 ─────────────────────────────────────────────────────────────────
    @Volatile private var contrast: Float = 1.0f
    @Volatile private var saturation: Float = 1.0f
    @Volatile private var temperatureShift: Float = 0.0f
    @Volatile private var chromaticAberration: Float = 0.0f
    @Volatile private var noiseAmount: Float = 0.0f
    @Volatile private var vignetteAmount: Float = 0.0f
    @Volatile private var grainAmount: Float = 0.0f
    @Volatile private var sharpen: Float = 0.0f
    @Volatile private var time: Float = 0.0f
    @Volatile private var fisheyeMode: Float = 0.0f
    @Volatile private var previewMirrorX: Float = 0.0f
    @Volatile private var lensDistortion: Float = 0.0f
    @Volatile private var highlights: Float = 0.0f
    @Volatile private var shadows: Float = 0.0f
    @Volatile private var whites: Float = 0.0f
    @Volatile private var blacks: Float = 0.0f
    @Volatile private var clarity: Float = 0.0f
    @Volatile private var vibrance: Float = 0.0f
    @Volatile private var colorBiasR: Float = 0.0f
    @Volatile private var colorBiasG: Float = 0.0f
    @Volatile private var colorBiasB: Float = 0.0f
    @Volatile private var tintShift: Float = 0.0f
    @Volatile private var halationAmount: Float = 0.0f
    @Volatile private var bloomAmount: Float = 0.0f
    @Volatile private var grainSize: Float = 1.0f
    @Volatile private var luminanceNoise: Float = 0.0f
    @Volatile private var chromaNoise: Float = 0.0f
    @Volatile private var highlightRolloff: Float = 0.0f
    @Volatile private var paperTexture: Float = 0.0f
    @Volatile private var edgeFalloff: Float = 0.0f
    @Volatile private var exposureOffset: Float = 0.0f
    @Volatile private var exposureVariation: Float = 0.0f
    @Volatile private var cornerWarmShift: Float = 0.0f
    @Volatile private var centerGain: Float = 0.0f
    @Volatile private var developmentSoftness: Float = 0.0f
    @Volatile private var chemicalIrregularity: Float = 0.0f
    @Volatile private var skinHueProtect: Float = 0.0f
    @Volatile private var skinSatProtect: Float = 1.0f
    @Volatile private var skinLumaSoften: Float = 0.0f
    @Volatile private var skinRedLimit: Float = 1.0f
    @Volatile private var highlightRolloff2: Float = 0.0f
    @Volatile private var toneCurveStrength: Float = 0.0f
    @Volatile private var fadeAmount: Float = 0.0f
    @Volatile private var shadowTintR: Float = 0.0f
    @Volatile private var shadowTintG: Float = 0.0f
    @Volatile private var shadowTintB: Float = 0.0f
    @Volatile private var highlightTintR: Float = 0.0f
    @Volatile private var highlightTintG: Float = 0.0f
    @Volatile private var highlightTintB: Float = 0.0f
    @Volatile private var splitToneBalance: Float = 0.5f
    @Volatile private var lightLeakAmount: Float = 0.0f
    @Volatile private var lightLeakSeed: Float = 0.0f
    // #1 LUT 渲染参数
    @Volatile private var lutEnabled: Float = 0.0f
    @Volatile private var lutStrength: Float = 1.0f
    @Volatile private var lutSize: Float = 33.0f
    @Volatile private var lutPath: String = ""
    @Volatile private var deviceGamma: Float = 1.0f
    @Volatile private var deviceWhiteScaleR: Float = 1.0f
    @Volatile private var deviceWhiteScaleG: Float = 1.0f
    @Volatile private var deviceWhiteScaleB: Float = 1.0f
    @Volatile private var deviceCcm00: Float = 1.0f
    @Volatile private var deviceCcm01: Float = 0.0f
    @Volatile private var deviceCcm02: Float = 0.0f
    @Volatile private var deviceCcm10: Float = 0.0f
    @Volatile private var deviceCcm11: Float = 1.0f
    @Volatile private var deviceCcm12: Float = 0.0f
    @Volatile private var deviceCcm20: Float = 0.0f
    @Volatile private var deviceCcm21: Float = 0.0f
    @Volatile private var deviceCcm22: Float = 1.0f
    // #1 LUT 纹理缓存（与预览 LUT 路径缓存相同思路）
    private var lutTextureId: Int = 0
    private var cachedLutPath: String = ""
    @Volatile private var previewWidth: Int = 1280
    @Volatile private var previewHeight: Int = 720

    // ── 线程 ─────────────────────────────────────────────────────────────────
    private val glExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "CameraGLThread")
    }
    private val initialized = AtomicBoolean(false)

    // ── 初始化 ───────────────────────────────────────────────────────────────

    fun initialize(width: Int, height: Int) {
        if (initialized.get()) return
        previewWidth = width
        previewHeight = height

        val latch = CountDownLatch(1)
        glExecutor.execute {
            initGL(width, height)
            latch.countDown()
        }
        val ok = latch.await(2, TimeUnit.SECONDS)
        if (!ok) {
            Log.e(TAG, "GL initialization timed out after 2s")
        }
    }

    private fun initGL(width: Int, height: Int) {
        Log.d(TAG, "initGL start: ${width}x${height}")

        // ── 1. 获取 EGL display ──────────────────────────────────────────────
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
            Log.e(TAG, "eglGetDisplay failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }

        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            Log.e(TAG, "eglInitialize failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }
        Log.d(TAG, "EGL version: ${version[0]}.${version[1]}")

        // ── 2. 选择 EGL config ──────────────────────────────────────────────
        val attribList = intArrayOf(
            EGL14.EGL_RED_SIZE,         8,
            EGL14.EGL_GREEN_SIZE,       8,
            EGL14.EGL_BLUE_SIZE,        8,
            EGL14.EGL_ALPHA_SIZE,       8,
            EGL14.EGL_RENDERABLE_TYPE,  EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE,     EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, 1, numConfigs, 0)
            || numConfigs[0] == 0) {
            Log.e(TAG, "eglChooseConfig failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }
        val config = configs[0]!!

        // ── 3. 创建 EGL context（ES 3.0）────────────────────────────────────
        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            Log.w(TAG, "ES3 context failed, trying ES2")
            val ctx2Attribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, ctx2Attribs, 0)
        }
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            Log.e(TAG, "eglCreateContext failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }

        // ── 4. 设置 Flutter SurfaceTexture 的缓冲区大小 ─────────────────────
        flutterSurfaceTexture.setDefaultBufferSize(width, height)

        // ── 5. 创建 Window Surface ──────────────────────────────────────────
        val flutterSurface = Surface(flutterSurfaceTexture)
        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, flutterSurface, surfaceAttribs, 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            Log.e(TAG, "eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            flutterSurface.release()
            return
        }

        // ── 6. 激活 EGL context ──────────────────────────────────────────────
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            Log.e(TAG, "eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }

        // ── 7a. 编译 Pass 1 直通 Shader（OES → FBO）────────────────────────
        copyProgramId = createProgram(VERTEX_SHADER, COPY_FRAGMENT_SHADER)
        if (copyProgramId == 0) {
            Log.e(TAG, "Failed to create copy shader program")
            return
        }
        copyUCameraTexture = GLES30.glGetUniformLocation(copyProgramId, "uCameraTexture")
        copyUSTMatrix      = GLES30.glGetUniformLocation(copyProgramId, "uSTMatrix")
        copyAPositionLoc   = GLES30.glGetAttribLocation(copyProgramId, "aPosition")
        copyATexCoordLoc   = GLES30.glGetAttribLocation(copyProgramId, "aTexCoord")

        // ── 7b. 编译 Pass 2 效果 Shader（sampler2D）────────────────────────
        programId = createProgram(VERTEX_SHADER_PASS2, FRAGMENT_SHADER)
        if (programId == 0) {
            Log.e(TAG, "Failed to create effect shader program")
            return
        }

        // ── 8. 创建相机输入纹理（OES 外部纹理）──────────────────────────────
        val texIds = IntArray(1)
        GLES30.glGenTextures(1, texIds, 0)
        cameraTexId = texIds[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        // ── 8b. 创建 FBO + 2D 纹理（中间缓冲）──────────────────────────────
        val fboTexIds = IntArray(1)
        GLES30.glGenTextures(1, fboTexIds, 0)
        fboTexId = fboTexIds[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTexId)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        val fboIds = IntArray(1)
        GLES30.glGenFramebuffers(1, fboIds, 0)
        fboId = fboIds[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, fboTexId, 0)
        val fboStatus = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        if (fboStatus != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "FBO incomplete: 0x${Integer.toHexString(fboStatus)}")
            return
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        Log.d(TAG, "FBO created: ${width}x${height}")

        // ── 9. 创建 SurfaceTexture（相机帧输入）─────────────────────────────
        inputSurfaceTexture = SurfaceTexture(cameraTexId)
        inputSurfaceTexture!!.setDefaultBufferSize(width, height)
        inputSurfaceTexture!!.setOnFrameAvailableListener {
            glExecutor.execute { renderFrame() }
        }
        inputSurface = Surface(inputSurfaceTexture)

        // ── 10. 获取 Pass 2 uniform 位置 ────────────────────────────────────
        cachePass2Uniforms()

        // ── 11. 顶点缓冲 ─────────────────────────────────────────────────────
        vertexBuffer = ByteBuffer.allocateDirect(QUAD_VERTICES.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply { put(QUAD_VERTICES); position(0) }

        initialized.set(true)
        Log.d(TAG, "GL initialized successfully (2-pass): ${width}x${height}")
    }

    /** 缓存 Pass 2 效果 Shader 的所有 uniform/attrib 位置 */
    private fun cachePass2Uniforms() {
        uInputTexture         = GLES30.glGetUniformLocation(programId, "uInputTexture")
        uContrast             = GLES30.glGetUniformLocation(programId, "uContrast")
        uSaturation           = GLES30.glGetUniformLocation(programId, "uSaturation")
        uTemperatureShift     = GLES30.glGetUniformLocation(programId, "uTemperatureShift")
        uChromaticAberration  = GLES30.glGetUniformLocation(programId, "uChromaticAberration")
        uNoiseAmount          = GLES30.glGetUniformLocation(programId, "uNoiseAmount")
        uVignetteAmount       = GLES30.glGetUniformLocation(programId, "uVignetteAmount")
        uGrainAmount          = GLES30.glGetUniformLocation(programId, "uGrainAmount")
        uSharpen              = GLES30.glGetUniformLocation(programId, "uSharpen")
        uTime                 = GLES30.glGetUniformLocation(programId, "uTime")
        uTexelSize            = GLES30.glGetUniformLocation(programId, "uTexelSize")
        uFisheyeMode          = GLES30.glGetUniformLocation(programId, "uFisheyeMode")
        uAspectRatio          = GLES30.glGetUniformLocation(programId, "uAspectRatio")
        uLensDistortion       = GLES30.glGetUniformLocation(programId, "uLensDistortion")
        uMirrorX              = GLES30.glGetUniformLocation(programId, "uMirrorX")
        aPositionLoc          = GLES30.glGetAttribLocation(programId, "aPosition")
        aTexCoordLoc          = GLES30.glGetAttribLocation(programId, "aTexCoord")
        uHighlights           = GLES30.glGetUniformLocation(programId, "uHighlights")
        uShadows              = GLES30.glGetUniformLocation(programId, "uShadows")
        uWhites               = GLES30.glGetUniformLocation(programId, "uWhites")
        uBlacks               = GLES30.glGetUniformLocation(programId, "uBlacks")
        uClarity              = GLES30.glGetUniformLocation(programId, "uClarity")
        uVibrance             = GLES30.glGetUniformLocation(programId, "uVibrance")
        uColorBiasR           = GLES30.glGetUniformLocation(programId, "uColorBiasR")
        uColorBiasG           = GLES30.glGetUniformLocation(programId, "uColorBiasG")
        uColorBiasB           = GLES30.glGetUniformLocation(programId, "uColorBiasB")
        uTintShift            = GLES30.glGetUniformLocation(programId, "uTintShift")
        uHalationAmount       = GLES30.glGetUniformLocation(programId, "uHalationAmount")
        uBloomAmount          = GLES30.glGetUniformLocation(programId, "uBloomAmount")
        uGrainSize            = GLES30.glGetUniformLocation(programId, "uGrainSize")
        uLuminanceNoise       = GLES30.glGetUniformLocation(programId, "uLuminanceNoise")
        uChromaNoise          = GLES30.glGetUniformLocation(programId, "uChromaNoise")
        uHighlightRolloff     = GLES30.glGetUniformLocation(programId, "uHighlightRolloff")
        uPaperTexture         = GLES30.glGetUniformLocation(programId, "uPaperTexture")
        uEdgeFalloff          = GLES30.glGetUniformLocation(programId, "uEdgeFalloff")
        uExposureVariation    = GLES30.glGetUniformLocation(programId, "uExposureVariation")
        uCornerWarmShift      = GLES30.glGetUniformLocation(programId, "uCornerWarmShift")
        uCenterGain           = GLES30.glGetUniformLocation(programId, "uCenterGain")
        uDevelopmentSoftness  = GLES30.glGetUniformLocation(programId, "uDevelopmentSoftness")
        uChemicalIrregularity = GLES30.glGetUniformLocation(programId, "uChemicalIrregularity")
        uSkinHueProtect       = GLES30.glGetUniformLocation(programId, "uSkinHueProtect")
        uSkinSatProtect       = GLES30.glGetUniformLocation(programId, "uSkinSatProtect")
        uSkinLumaSoften       = GLES30.glGetUniformLocation(programId, "uSkinLumaSoften")
        uSkinRedLimit         = GLES30.glGetUniformLocation(programId, "uSkinRedLimit")
        uHighlightRolloff2    = GLES30.glGetUniformLocation(programId, "uHighlightRolloff2")
        uToneCurveStrength    = GLES30.glGetUniformLocation(programId, "uToneCurveStrength")
        uFadeAmount           = GLES30.glGetUniformLocation(programId, "uFadeAmount")
        uShadowTint           = GLES30.glGetUniformLocation(programId, "uShadowTint")
        uHighlightTint        = GLES30.glGetUniformLocation(programId, "uHighlightTint")
        uSplitToneBalance     = GLES30.glGetUniformLocation(programId, "uSplitToneBalance")
        uLightLeakAmount      = GLES30.glGetUniformLocation(programId, "uLightLeakAmount")
        uLightLeakSeed        = GLES30.glGetUniformLocation(programId, "uLightLeakSeed")
        uExposureOffset       = GLES30.glGetUniformLocation(programId, "uExposureOffset")
        // #1 LUT uniform 位置
        uLutTexture           = GLES30.glGetUniformLocation(programId, "uLutTexture")
        uLutEnabled           = GLES30.glGetUniformLocation(programId, "uLutEnabled")
        uLutStrength          = GLES30.glGetUniformLocation(programId, "uLutStrength")
        uLutSize              = GLES30.glGetUniformLocation(programId, "uLutSize")
        uDeviceGamma          = GLES30.glGetUniformLocation(programId, "uDeviceGamma")
        uDeviceWhiteScale     = GLES30.glGetUniformLocation(programId, "uDeviceWhiteScale")
        uDeviceCcm            = GLES30.glGetUniformLocation(programId, "uDeviceCcm")
    }

    // ── 渲染（两步架构）─────────────────────────────────────────────────────

    private fun renderFrame() {
        if (!initialized.get()) return

        val skipRender = (programId == 0 || copyProgramId == 0)

        val eglOk = EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        if (!eglOk) {
            Log.w(TAG, "renderFrame: eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }

        // 更新相机帧纹理（无论是否渲染都必须消费，否则帧积压导致斜条纹）
        try {
            inputSurfaceTexture?.updateTexImage()
            inputSurfaceTexture?.getTransformMatrix(stMatrix)
        } catch (e: Exception) {
            Log.w(TAG, "updateTexImage failed: ${e.message}")
            return
        }

        if (skipRender || !eglOk) return

        val vb = vertexBuffer ?: return
        val stride = 4 * 4 // 4 floats * 4 bytes

        // ════════════════════════════════════════════════════════════════════
        // Pass 1: OES → FBO（将 OES 纹理拷贝到稳定的 2D 纹理）
        // ════════════════════════════════════════════════════════════════════
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glViewport(0, 0, previewWidth, previewHeight)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        GLES30.glUseProgram(copyProgramId)

        // 绑定 OES 纹理
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexId)
        GLES30.glUniform1i(copyUCameraTexture, 0)

        // 传入 ST 矩阵（修正 OES 纹理方向）
        GLES30.glUniformMatrix4fv(copyUSTMatrix, 1, false, stMatrix, 0)

        // 绘制全屏四边形
        vb.position(0)
        GLES30.glEnableVertexAttribArray(copyAPositionLoc)
        GLES30.glVertexAttribPointer(copyAPositionLoc, 2, GLES30.GL_FLOAT, false, stride, vb)
        vb.position(2)
        GLES30.glEnableVertexAttribArray(copyATexCoordLoc)
        GLES30.glVertexAttribPointer(copyATexCoordLoc, 2, GLES30.GL_FLOAT, false, stride, vb)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(copyAPositionLoc)
        GLES30.glDisableVertexAttribArray(copyATexCoordLoc)

        // ════════════════════════════════════════════════════════════════════
        // Pass 2: 效果处理（从稳定的 2D 纹理采样）
        // ════════════════════════════════════════════════════════════════════
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0) // 渲染到屏幕
        GLES30.glViewport(0, 0, previewWidth, previewHeight)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        GLES30.glUseProgram(programId)

        // 绑定 FBO 的 2D 纹理（而非 OES 纹理）
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTexId)
        GLES30.glUniform1i(uInputTexture, 0)

        // 设置所有效果 uniform 参数
        GLES30.glUniform1f(uContrast,            contrast)
        GLES30.glUniform1f(uSaturation,          saturation)
        GLES30.glUniform1f(uTemperatureShift,    temperatureShift)
        GLES30.glUniform1f(uChromaticAberration, chromaticAberration)
        GLES30.glUniform1f(uNoiseAmount,         noiseAmount)
        GLES30.glUniform1f(uVignetteAmount,      vignetteAmount)
        GLES30.glUniform1f(uGrainAmount,         grainAmount)
        GLES30.glUniform1f(uSharpen,             sharpen)
        GLES30.glUniform1f(uTime,                time)
        GLES30.glUniform2f(uTexelSize,
            1f / previewWidth.toFloat(),
            1f / previewHeight.toFloat())
        GLES30.glUniform1f(uFisheyeMode,         fisheyeMode)
        // FIX: use min/max so aspect is always <= 1.0 regardless of frame orientation.
        // fisheyeUV does p.x *= aspect to compress the horizontal axis to match the vertical,
        // producing a physically round circle. aspect must be shortEdge/longEdge (<= 1.0).
        val pw = previewWidth.toFloat()
        val ph = previewHeight.toFloat()
        GLES30.glUniform1f(uAspectRatio, minOf(pw, ph) / maxOf(pw, ph))
        GLES30.glUniform1f(uLensDistortion,      lensDistortion)
        GLES30.glUniform1f(uMirrorX,             previewMirrorX)
        GLES30.glUniform1f(uHighlights,          highlights)
        GLES30.glUniform1f(uShadows,             shadows)
        GLES30.glUniform1f(uWhites,              whites)
        GLES30.glUniform1f(uBlacks,              blacks)
        GLES30.glUniform1f(uClarity,             clarity)
        GLES30.glUniform1f(uVibrance,            vibrance)
        GLES30.glUniform1f(uColorBiasR,          colorBiasR)
        GLES30.glUniform1f(uColorBiasG,          colorBiasG)
        GLES30.glUniform1f(uColorBiasB,          colorBiasB)
        GLES30.glUniform1f(uTintShift,           tintShift)
        GLES30.glUniform1f(uHalationAmount,      halationAmount)
        GLES30.glUniform1f(uBloomAmount,         bloomAmount)
        GLES30.glUniform1f(uGrainSize,           grainSize)
        GLES30.glUniform1f(uLuminanceNoise,      luminanceNoise)
        GLES30.glUniform1f(uChromaNoise,         chromaNoise)
        GLES30.glUniform1f(uHighlightRolloff,    highlightRolloff)
        GLES30.glUniform1f(uPaperTexture,        paperTexture)
        GLES30.glUniform1f(uEdgeFalloff,         edgeFalloff)
        GLES30.glUniform1f(uExposureVariation,   exposureVariation)
        GLES30.glUniform1f(uCornerWarmShift,     cornerWarmShift)
        GLES30.glUniform1f(uCenterGain,          centerGain)
        GLES30.glUniform1f(uDevelopmentSoftness, developmentSoftness)
        GLES30.glUniform1f(uChemicalIrregularity, chemicalIrregularity)
        GLES30.glUniform1f(uSkinHueProtect,      skinHueProtect)
        GLES30.glUniform1f(uSkinSatProtect,      skinSatProtect)
        GLES30.glUniform1f(uSkinLumaSoften,      skinLumaSoften)
        GLES30.glUniform1f(uSkinRedLimit,        skinRedLimit)
        GLES30.glUniform1f(uHighlightRolloff2,   highlightRolloff2)
        GLES30.glUniform1f(uToneCurveStrength,   toneCurveStrength)
        GLES30.glUniform1f(uFadeAmount,           fadeAmount)
        GLES30.glUniform3f(uShadowTint,           shadowTintR, shadowTintG, shadowTintB)
        GLES30.glUniform3f(uHighlightTint,        highlightTintR, highlightTintG, highlightTintB)
        GLES30.glUniform1f(uSplitToneBalance,     splitToneBalance)
         GLES30.glUniform1f(uLightLeakAmount,      lightLeakAmount)
        GLES30.glUniform1f(uLightLeakSeed,        lightLeakSeed)
        GLES30.glUniform1f(uExposureOffset,       exposureOffset)
        // #1 LUT uniform 设置
        GLES30.glUniform1f(uLutEnabled,  lutEnabled)
        GLES30.glUniform1f(uLutStrength, lutStrength)
        GLES30.glUniform1f(uLutSize,     lutSize)
        GLES30.glUniform1f(uDeviceGamma, deviceGamma)
        GLES30.glUniform3f(uDeviceWhiteScale, deviceWhiteScaleR, deviceWhiteScaleG, deviceWhiteScaleB)
        // GLSL mat3 uniform 采用列主序；toJson 传入为 row-major（00..22），这里做重排。
        val deviceCcmCols = floatArrayOf(
            deviceCcm00, deviceCcm10, deviceCcm20,
            deviceCcm01, deviceCcm11, deviceCcm21,
            deviceCcm02, deviceCcm12, deviceCcm22
        )
        GLES30.glUniformMatrix3fv(uDeviceCcm, 1, false, deviceCcmCols, 0)
        if (lutEnabled > 0.5f && lutTextureId != 0) {
            GLES30.glActiveTexture(GLES30.GL_TEXTURE2)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, lutTextureId)
            GLES30.glUniform1i(uLutTexture, 2)
        }
        time += 0.016f
        // 绘制全屏四边形
        vb.position(0)
        GLES30.glEnableVertexAttribArray(aPositionLoc)
        GLES30.glVertexAttribPointer(aPositionLoc, 2, GLES30.GL_FLOAT, false, stride, vb)

        vb.position(2)
        GLES30.glEnableVertexAttribArray(aTexCoordLoc)
        GLES30.glVertexAttribPointer(aTexCoordLoc, 2, GLES30.GL_FLOAT, false, stride, vb)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(aPositionLoc)
        GLES30.glDisableVertexAttribArray(aTexCoordLoc)

        // 提交帧到 Flutter SurfaceTexture
        if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
            Log.w(TAG, "eglSwapBuffers failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
    }

    // ── 参数更新 API ──────────────────────────────────────────────────────────

    fun updateParams(params: Map<String, Any>) {
        fun numberOrNull(v: Any?): Float? = when (v) {
            is Number -> v.toFloat()
            is String -> v.toFloatOrNull()
            else -> null
        }
        (params["contrast"]            as? Number)?.let { contrast            = it.toFloat() }
        (params["saturation"]          as? Number)?.let { saturation          = it.toFloat() }
        (params["temperatureShift"]    as? Number)?.let { temperatureShift    = it.toFloat() }
        (params["chromaticAberration"] as? Number)?.let { chromaticAberration = it.toFloat() }
        (params["noise"]               as? Number)?.let { noiseAmount         = it.toFloat() }
        (params["noiseAmount"]         as? Number)?.let { noiseAmount         = it.toFloat() }
        (params["vignette"]            as? Number)?.let { vignetteAmount      = it.toFloat() }
        (params["vignetteAmount"]      as? Number)?.let { vignetteAmount      = it.toFloat() }
        (params["grain"]               as? Number)?.let { grainAmount         = it.toFloat() }
        (params["grainAmount"]         as? Number)?.let { grainAmount         = it.toFloat() }
        (params["sharpen"]             as? Number)?.let { sharpen             = it.toFloat() }
        (params["highlights"]          as? Number)?.let { highlights          = it.toFloat() }
        (params["shadows"]             as? Number)?.let { shadows             = it.toFloat() }
        (params["whites"]              as? Number)?.let { whites              = it.toFloat() }
        (params["blacks"]              as? Number)?.let { blacks              = it.toFloat() }
        (params["clarity"]             as? Number)?.let { clarity             = it.toFloat() }
        (params["vibrance"]            as? Number)?.let { vibrance            = it.toFloat() }
        (params["colorBiasR"]          as? Number)?.let { colorBiasR          = it.toFloat() }
        (params["colorBiasG"]          as? Number)?.let { colorBiasG          = it.toFloat() }
        (params["colorBiasB"]          as? Number)?.let { colorBiasB          = it.toFloat() }
        (params["tintShift"]           as? Number)?.let { tintShift           = it.toFloat() }
        (params["halationAmount"]      as? Number)?.let { halationAmount      = it.toFloat() }
        (params["bloomAmount"]         as? Number)?.let { bloomAmount         = it.toFloat() }
        (params["grainSize"]           as? Number)?.let { grainSize           = it.toFloat() }
        (params["luminanceNoise"]      as? Number)?.let { luminanceNoise      = it.toFloat() }
        (params["chromaNoise"]         as? Number)?.let { chromaNoise         = it.toFloat() }
        (params["highlightRolloff"]    as? Number)?.let { highlightRolloff    = it.toFloat() }
        (params["paperTexture"]        as? Number)?.let { paperTexture        = it.toFloat() }
        (params["edgeFalloff"]         as? Number)?.let { edgeFalloff         = it.toFloat() }
        (params["exposureVariation"]   as? Number)?.let { exposureVariation   = it.toFloat() }
        (params["cornerWarmShift"]     as? Number)?.let { cornerWarmShift     = it.toFloat() }
        (params["centerGain"]          as? Number)?.let { centerGain          = it.toFloat() }
        (params["developmentSoftness"] as? Number)?.let { developmentSoftness = it.toFloat() }
        (params["chemicalIrregularity"] as? Number)?.let { chemicalIrregularity = it.toFloat() }
        (params["skinHueProtect"]      as? Number)?.let { skinHueProtect      = it.toFloat() }
        (params["skinSatProtect"]      as? Number)?.let { skinSatProtect      = it.toFloat() }
        (params["skinLumaSoften"]      as? Number)?.let { skinLumaSoften      = it.toFloat() }
        (params["skinRedLimit"]        as? Number)?.let { skinRedLimit        = it.toFloat() }
        (params["highlightRolloff2"]    as? Number)?.let { highlightRolloff2    = it.toFloat() }
        (params["toneCurveStrength"]    as? Number)?.let { toneCurveStrength    = it.toFloat() }
        (params["lutStrength"]          as? Number)?.let { lutStrength          = it.toFloat().coerceIn(0.0f, 1.0f) }
        (params["lensVignette"]         as? Number)?.let { vignetteAmount      = it.toFloat() }
        (params["exposureOffset"]       as? Number)?.let { exposureOffset       = it.toFloat() }
        (params["softFocus"]            as? Number)?.let { /* TODO: 添加 softFocus uniform */ }
        (params["distortion"]           as? Number)?.let { lensDistortion      = it.toFloat() }
        // ── 新增：Fade / Split Toning / Light Leak ──
        (params["fadeAmount"]           as? Number)?.let { fadeAmount          = it.toFloat() }
        (params["fade"]                 as? Number)?.let { fadeAmount          = it.toFloat() }
        (params["shadowTintR"]          as? Number)?.let { shadowTintR         = it.toFloat() }
        (params["shadowTintG"]          as? Number)?.let { shadowTintG         = it.toFloat() }
        (params["shadowTintB"]          as? Number)?.let { shadowTintB         = it.toFloat() }
        (params["highlightTintR"]       as? Number)?.let { highlightTintR      = it.toFloat() }
        (params["highlightTintG"]       as? Number)?.let { highlightTintG      = it.toFloat() }
        (params["highlightTintB"]       as? Number)?.let { highlightTintB      = it.toFloat() }
        (params["splitToneBalance"]     as? Number)?.let { splitToneBalance    = it.toFloat() }
        (params["lightLeakAmount"]      as? Number)?.let { lightLeakAmount     = it.toFloat() }
        (params["lightLeakSeed"]        as? Number)?.let { lightLeakSeed       = it.toFloat() }
        numberOrNull(params["deviceGamma"])?.let { deviceGamma = it }
        numberOrNull(params["deviceWhiteScaleR"])?.let { deviceWhiteScaleR = it }
        numberOrNull(params["deviceWhiteScaleG"])?.let { deviceWhiteScaleG = it }
        numberOrNull(params["deviceWhiteScaleB"])?.let { deviceWhiteScaleB = it }
        numberOrNull(params["deviceCcm00"])?.let { deviceCcm00 = it }
        numberOrNull(params["deviceCcm01"])?.let { deviceCcm01 = it }
        numberOrNull(params["deviceCcm02"])?.let { deviceCcm02 = it }
        numberOrNull(params["deviceCcm10"])?.let { deviceCcm10 = it }
        numberOrNull(params["deviceCcm11"])?.let { deviceCcm11 = it }
        numberOrNull(params["deviceCcm12"])?.let { deviceCcm12 = it }
        numberOrNull(params["deviceCcm20"])?.let { deviceCcm20 = it }
        numberOrNull(params["deviceCcm21"])?.let { deviceCcm21 = it }
        numberOrNull(params["deviceCcm22"])?.let { deviceCcm22 = it }
        // #1 LUT 参数处理（路径缓存：相同路径不重复加载）
        val newLutPath = (params["baseLut"] as? String) ?: ""
        if (newLutPath != lutPath) {
            lutPath = newLutPath
            if (newLutPath.isNotEmpty()) {
                glExecutor.execute {
                    val context = contextRef?.get() ?: return@execute
                    if (newLutPath != cachedLutPath) {
                        val texId = loadLutTextureGL(context, newLutPath)
                        if (texId != 0) {
                            if (lutTextureId != 0) GLES30.glDeleteTextures(1, intArrayOf(lutTextureId), 0)
                            lutTextureId = texId
                            cachedLutPath = newLutPath
                        }
                    }
                    lutEnabled = if (lutTextureId != 0) 1.0f else 0.0f
                    lutSize = 33.0f
                }
            } else {
                lutEnabled = 0.0f
            }
        }
    }

    fun setCameraId(cameraId: String) {
        // ── FIX: FRAGMENT_SHADER 是编译期常量，不依赖 cameraId。
        // 旧代码在此处异步重编译 shader，存在严重的竞态风险：
        //   1. 重编译期间 programId=0 → renderFrame 跳过渲染（画面瞬间黑屏）
        //   2. 如果 eglMakeCurrent 或 createProgram 失败，programId 永久为 0，
        //      而 currentCameraId 已被设置，后续调用会因早期返回而永远无法恢复。
        // 因此移除不必要的重编译，仅更新 cameraId 标记。
        // initGL 中已经编译了正确的 shader 并缓存了 uniform 位置。
        currentCameraId = cameraId
        pendingCameraId = cameraId
        Log.d(TAG, "setCameraId: updated to cameraId=$cameraId (no shader recompile needed)")
    }

    fun setSharpen(level: Float) {
        sharpen = level
    }

    fun setFisheyeMode(enabled: Boolean) {
        fisheyeMode = if (enabled) 1.0f else 0.0f
    }

    fun setPreviewMirror(enabled: Boolean) {
        previewMirrorX = if (enabled) 1.0f else 0.0f
    }

    // ── 获取相机输入 Surface ──────────────────────────────────────────────────

    fun getInputSurface(): Surface? = if (initialized.get()) inputSurface else null

    // ── 释放 ─────────────────────────────────────────────────────────────────

    fun release() {
        glExecutor.execute {
            initialized.set(false)
            inputSurface?.release()
            inputSurface = null
            inputSurfaceTexture?.release()
            inputSurfaceTexture = null
            if (programId != 0) {
                GLES30.glDeleteProgram(programId)
                programId = 0
            }
            if (copyProgramId != 0) {
                GLES30.glDeleteProgram(copyProgramId)
                copyProgramId = 0
            }
            if (fboId != 0) {
                GLES30.glDeleteFramebuffers(1, intArrayOf(fboId), 0)
                fboId = 0
            }
            if (fboTexId != 0) {
                GLES30.glDeleteTextures(1, intArrayOf(fboTexId), 0)
                fboTexId = 0
            }
            if (cameraTexId != 0) {
                GLES30.glDeleteTextures(1, intArrayOf(cameraTexId), 0)
                cameraTexId = 0
            }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    eglDisplay,
                    EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT
                )
                if (eglSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(eglDisplay, eglSurface)
                    eglSurface = EGL14.EGL_NO_SURFACE
                }
                EGL14.eglDestroyContext(eglDisplay, eglContext)
                eglContext = EGL14.EGL_NO_CONTEXT
                EGL14.eglTerminate(eglDisplay)
                eglDisplay = EGL14.EGL_NO_DISPLAY
            }
        }
        glExecutor.shutdown()
    }

    // ── 着色器编译工具 ────────────────────────────────────────────────────────

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        if (shader == 0) {
            Log.e(TAG, "glCreateShader failed")
            return 0
        }
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == GLES30.GL_FALSE) {
            Log.e(TAG, "Shader compile error [type=$type]: ${GLES30.glGetShaderInfoLog(shader)}")
            GLES30.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    // #1 LUT 纹理加载（在 GL 线程中调用）
    private fun loadLutTextureGL(context: Context, assetPath: String): Int {
        return try {
            val inputStream = context.assets.open(assetPath.removePrefix("assets/"))
            val lines = inputStream.bufferedReader().readLines()
            inputStream.close()
            var lutSize = 33
            val data = mutableListOf<Float>()
            for (line in lines) {
                val trimmed = line.trim()
                if (trimmed.startsWith("LUT_3D_SIZE")) {
                    lutSize = trimmed.split("\\s+".toRegex()).getOrNull(1)?.toIntOrNull() ?: 33
                    continue
                }
                if (trimmed.isEmpty() || trimmed.startsWith("#") || trimmed.startsWith("TITLE")
                    || trimmed.startsWith("DOMAIN") || trimmed.startsWith("LUT")) continue
                val parts = trimmed.split("\\s+".toRegex())
                if (parts.size >= 3) {
                    data.add(parts[0].toFloatOrNull() ?: continue)
                    data.add(parts[1].toFloatOrNull() ?: continue)
                    data.add(parts[2].toFloatOrNull() ?: continue)
                }
            }
            // 将 3D LUT 平铺为 2D 纹理（N*N × N，B-fastest 排列）
            val n = lutSize
            val pixels = ByteBuffer.allocateDirect(n * n * n * 4).order(ByteOrder.nativeOrder())
            for (i in 0 until n * n * n) {
                val r = (data.getOrElse(i * 3) { 0f } * 255f + 0.5f).toInt().coerceIn(0, 255)
                val g = (data.getOrElse(i * 3 + 1) { 0f } * 255f + 0.5f).toInt().coerceIn(0, 255)
                val b = (data.getOrElse(i * 3 + 2) { 0f } * 255f + 0.5f).toInt().coerceIn(0, 255)
                pixels.put(r.toByte()); pixels.put(g.toByte()); pixels.put(b.toByte()); pixels.put(255.toByte())
            }
            pixels.rewind()
            val texIds = IntArray(1)
            GLES30.glGenTextures(1, texIds, 0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texIds[0])
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA, n * n, n, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, pixels)
            texIds[0]
        } catch (e: Exception) {
            Log.e(TAG, "loadLutTextureGL failed: $assetPath", e)
            0
        }
    }
    private fun createProgram(vertSrc: String, fragSrc: String): Int {
        val vert = compileShader(GLES30.GL_VERTEX_SHADER, vertSrc)
        val frag = compileShader(GLES30.GL_FRAGMENT_SHADER, fragSrc)
        if (vert == 0 || frag == 0) return 0

        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vert)
        GLES30.glAttachShader(program, frag)
        GLES30.glLinkProgram(program)

        val status = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
        if (status[0] == GLES30.GL_FALSE) {
            Log.e(TAG, "Program link error: ${GLES30.glGetProgramInfoLog(program)}")
            GLES30.glDeleteProgram(program)
            return 0
        }
        GLES30.glDeleteShader(vert)
        GLES30.glDeleteShader(frag)
        return program
    }
}
