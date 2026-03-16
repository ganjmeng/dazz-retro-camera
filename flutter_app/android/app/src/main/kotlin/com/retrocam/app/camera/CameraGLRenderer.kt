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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * CameraGLRenderer — 修复版
 *
 * 渲染链：
 *   CameraX Preview → inputSurfaceTexture (GL_TEXTURE_EXTERNAL_OES)
 *     → 片段着色器（色差 / 对比度 / 饱和度 / 颗粒 / 暗角 / Unsharp Mask 锐化）
 *     → eglSwapBuffers → Flutter SurfaceTexture（Window Surface）
 *
 * 修复的关键问题：
 * 1. eglCreateWindowSurface 必须在 flutterSurfaceTexture.setDefaultBufferSize() 之后调用
 * 2. 必须检查 eglCreateWindowSurface 返回值，失败时记录 EGL 错误码
 * 3. uGrainTexture 改为纯噪点（不依赖外部纹理文件），避免未绑定纹理导致 GL 错误
 * 4. renderFrame() 中每次都调用 eglMakeCurrent，确保 GL context 在正确线程激活
 * 5. initialize() 通过 CountDownLatch 同步，调用方不在 glExecutor 上等待
 */
class CameraGLRenderer(
    private val flutterSurfaceTexture: SurfaceTexture
) {
    companion object {
        private const val TAG = "CameraGLRenderer"

                // ── 顶点着色器 ──────────────────────────────────────────────
        private const val VERTEX_SHADER = """#version 300 es
in vec4 aPosition;
in vec2 aTexCoord;
out vec2 vTexCoord;
uniform mat4 uSTMatrix;
void main() {
    gl_Position = aPosition;
    // 使用 SurfaceTexture.getTransformMatrix() 修正 OES 纹理方向
    vTexCoord = (uSTMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
}"""

        // ── 片段着色器（OES 外部纹理 + CCD 效果 + Unsharp Mask 锐化）──────────
        // 注意：去掉了 uGrainTexture sampler2D，改用程序化噪点，避免未绑定纹理错误
        private const val FRAGMENT_SHADER = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;

in  vec2 vTexCoord;
out vec4 fragColor;

uniform samplerExternalOES uCameraTexture;

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

// ── 工具函数 ──────────────────────────────────────────────────────────────────
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
    // Input:  0     16    32    64    96    128   160   192   224   255
    // Output: 0     10    24    57    92    124   168   210   238   250
    float[10] inp = float[10](0.0, 0.0627, 0.1255, 0.2510, 0.3765, 0.5020, 0.6275, 0.7529, 0.8784, 1.0);
    float[10] out = float[10](0.0, 0.0392, 0.0941, 0.2235, 0.3608, 0.4863, 0.6588, 0.8235, 0.9333, 0.9804);
    for (int i = 0; i < 9; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(out[i], out[i + 1], t);
        }
    }
    return out[9];
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
    // 正值 = 偏暖（加R减B），负值 = 偏冷（减R加B）
    // shift 范围 -200~+200，/1000 后约 ±0.2
    float s = shift / 1000.0;
    c.r = clamp(c.r + s * 0.3, 0.0, 1.0);
    c.b = clamp(c.b - s * 0.3, 0.0, 1.0);
    return c;
}

float vignetteEffect(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return 1.0 - dot(d, d) * amount * 2.5;
}

// Unsharp Mask: 3x3 高斯模糊 + 差值增强
vec3 applySharpen(vec2 uv, float amount) {
    vec3 center = texture(uCameraTexture, uv).rgb;
    if (amount <= 0.0) return center;

    vec3 blur =
        texture(uCameraTexture, uv + vec2(-uTexelSize.x, -uTexelSize.y)).rgb * 1.0 +
        texture(uCameraTexture, uv + vec2( 0.0,          -uTexelSize.y)).rgb * 2.0 +
        texture(uCameraTexture, uv + vec2( uTexelSize.x, -uTexelSize.y)).rgb * 1.0 +
        texture(uCameraTexture, uv + vec2(-uTexelSize.x,  0.0         )).rgb * 2.0 +
        center                                                                * 4.0 +
        texture(uCameraTexture, uv + vec2( uTexelSize.x,  0.0         )).rgb * 2.0 +
        texture(uCameraTexture, uv + vec2(-uTexelSize.x,  uTexelSize.y)).rgb * 1.0 +
        texture(uCameraTexture, uv + vec2( 0.0,           uTexelSize.y)).rgb * 2.0 +
        texture(uCameraTexture, uv + vec2( uTexelSize.x,  uTexelSize.y)).rgb * 1.0;
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
        texture(uCameraTexture, uv + vec2(-uTexelSize.x, 0.0)).rgb * 0.25 +
        texture(uCameraTexture, uv + vec2( uTexelSize.x, 0.0)).rgb * 0.25 +
        texture(uCameraTexture, uv + vec2(0.0, -uTexelSize.y)).rgb * 0.25 +
        texture(uCameraTexture, uv + vec2(0.0,  uTexelSize.y)).rgb * 0.25;
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
// 等距投影：将屏幕像素映射到球面，圆形以外输出纯黑
// 原理：以画面中心为原点，将 [-1,1] 的归一化坐标做极坐标变换，
//       r = sqrt(x²+y²) 是到中心的距离，r>1 时为圆外（黑色）
//       圆内通过等距投影反算纹理坐标，产生强烈桶形畸变
vec2 fisheyeUV(vec2 uv, float aspect) {
    // 转为以中心为原点的坐标，并修正宽高比使圆形不变形
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= aspect; // 修正宽高比
    float r = length(p);
    if (r > 1.0) return vec2(-1.0); // 圆外标记
    // 等距投影：theta = r * (π/2)，即 r=1 对应 90° 视角边缘
    float theta = r * 1.5707963; // π/2
    float phi = atan(p.y, p.x);
    // 球面坐标反算纹理坐标（等距投影到平面）
    float sinTheta = sin(theta);
    vec2 texCoord = vec2(
        sinTheta * cos(phi),
        sinTheta * sin(phi)
    );
    // 映射回 [0,1]
    texCoord = texCoord * 0.5 + 0.5;
    return texCoord;
}

// ── 主函数 ────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;
    bool isCircleOutside = false;

    // 鱼眼模式：重映射 UV 坐标
    if (uFisheyeMode > 0.5) {
        vec2 fUV = fisheyeUV(uv, uAspectRatio);
        if (fUV.x < 0.0) {
            // 圆形以外：输出纯黑
            fragColor = vec4(0.0, 0.0, 0.0, 1.0);
            return;
        }
        uv = fUV;
    }

    // Pass 0: 锐化 (Unsharp Mask)
    vec3 color = applySharpen(uv, uSharpen);

    // Pass 1: 色差 (Chromatic Aberration)
    // ca 字段范围 0~1.0，乘以 uTexelSize.x * 20.0 转换为像素级偏移
    // 例：ca=0.18 在 1080p 下≈ 0.18*20*(1/1080) ≈ 0.003 UV 单位 ≈ 3px，视觉上轻微色差
    if (uChromaticAberration > 0.0) {
        float ca = uChromaticAberration * uTexelSize.x * 20.0;
        float r = texture(uCameraTexture, uv + vec2(ca, 0.0)).r;
        float g = texture(uCameraTexture, uv).g;
        float b = texture(uCameraTexture, uv - vec2(ca, 0.0)).b;
        color = vec3(r, g, b);
    }

    // Pass 2: 基础色彩调整
    color = applyTemperature(color, uTemperatureShift);
    color = applyContrast(color, uContrast);
    color = applySaturation(color, uSaturation);

    // Pass 3: 程序化胶片颗粒（不依赖外部纹理）
    if (uGrainAmount > 0.0) {
        float grain = random(uv, floor(uTime * 24.0) / 24.0) - 0.5;
        color = clamp(color + grain * uGrainAmount * 0.25, 0.0, 1.0);
    }

    // Pass 4: 动态数字噪点
    if (uNoiseAmount > 0.0) {
        float lum   = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float noise = random(uv, uTime) - 0.5;
        float dark  = 1.0 - lum;
        color = clamp(color + noise * uNoiseAmount * 0.2 * dark, 0.0, 1.0);
    }
    // FXN-R: luminanceNoise=0.02, chromaNoise=0.01
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

    // Pass 5: 传感器非均匀性 + 肤色保护
    // FXN-R: centerGain=0.010, edgeFalloff=0.035
    if (uCenterGain > 0.0 || uEdgeFalloff > 0.0) {
        float factor = ccdCenterEdge(uv, uCenterGain, uEdgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    // FXN-R: exposureVariation=0.020
    if (uExposureVariation > 0.0) {
        float evn = random(uv * 0.1, uTime * 0.01) - 0.5;
        color = clamp(color + evn * uExposureVariation * 0.3, 0.0, 1.0);
    }
    // FXN-R: cornerWarmShift=-0.015 (负値=偏冷青)
    if (uCornerWarmShift != 0.0) {
        color = ccdCornerWarm(uv, color, uCornerWarmShift);
    }
    // FXN-R: developmentSoftness=0.020
    if (uDevelopmentSoftness > 0.0) {
        color = ccdDevelopmentSoften(uv, color, uDevelopmentSoftness);
    }
    // FXN-R: skinHueProtect=1.0, skinSatProtect=0.96, skinLumaSoften=0.03, skinRedLimit=1.04
    color = ccdSkinProtect(color, uSkinHueProtect, uSkinSatProtect, uSkinLumaSoften, uSkinRedLimit);

    // Pass 6: 高光柔和滚落（Highlight Rolloff）
    // FXN-R=0.16：高光层次保留，防止过曝失真
    if (uHighlightRolloff2 > 0.0) {
        color = ccdHighlightRolloff(color, uHighlightRolloff2);
    }
    // Pass 7: Tone Curve
    // FXN-R Tone Curve：阴影压、中间调通透、高光滚落
    if (uToneCurveStrength > 0.0) {
        vec3 curved = vec3(
            fxnrToneCurve(color.r),
            fxnrToneCurve(color.g),
            fxnrToneCurve(color.b)
        );
        color = mix(color, curved, uToneCurveStrength);
    }
    // Pass 8: 暗角（鱼眼模式下不叠加额外暗角，圆形边缘已有自然渐暗）
    if (uFisheyeMode < 0.5) {
        float vignette = vignetteEffect(uv, uVignetteAmount);
        color *= vignette;
    }

    fragColor = vec4(color, 1.0);
}"""

        // 全屏四边形顶点（位置 + UV）
        // UV Y 轴翻转（0 在底部，1 在顶部），配合 uSTMatrix 修正 OES 纹理方向
        // 注意：OES 纹理 + SurfaceTexture.getTransformMatrix() 需要 UV 从底部开始
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
    private var programId: Int = 0
    private var cameraTexId: Int = 0
    private var vertexBuffer: FloatBuffer? = null

    // Uniform 位置（初始化时缓存，避免每帧 glGetUniformLocation 调用）
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
    private var uSTMatrix: Int = -1
    private var uFisheyeMode: Int = -1
    private var uAspectRatio: Int = -1
    private var uCameraTexture: Int = -1  // 性能优化：缓存 sampler uniform 位置
    // FQS/CPM35 专有 uniform 位置（通用 Shader 中不存在，glGetUniformLocation 返回 -1，glUniform1f(-1,...) 是 no-op）
    private var uColorBiasR: Int = -1
    private var uColorBiasG: Int = -1
    private var uColorBiasB: Int = -1
    private var uTintShift: Int = -1
    private var uHalationAmount: Int = -1
    private var uBloomAmount: Int = -1
    private var uGrainSize: Int = -1
    private var uLuminanceNoise: Int = -1
    private var uChromaNoise: Int = -1
    // Inst C / SQC 共用 uniform 位置
    private var uHighlightRolloff: Int = -1
    private var uPaperTexture: Int = -1
    private var uEdgeFalloff: Int = -1
    private var uExposureVariation: Int = -1
    private var uCornerWarmShift: Int = -1
    // 拍立得/数码通用 uniform 位置（Inst C / SQC / FXN-R 共用）
    private var uCenterGain: Int = -1
    private var uDevelopmentSoftness: Int = -1
    private var uChemicalIrregularity: Int = -1
    private var uSkinHueProtect: Int = -1
    private var uSkinSatProtect: Int = -1
    private var uSkinLumaSoften: Int = -1
    private var uSkinRedLimit: Int = -1
    // LUT + Tone Curve + Highlight Rolloff uniform 位置
    private var uHighlightRolloff2: Int = -1
    private var uToneCurveStrength: Int = -1

    // Attrib 位置（初始化时缓存，避免每帧 glGetAttribLocation 调用 — 关键热路径优化）
    // glGetAttribLocation 是同步 GPU driver 查询，每帧调用在高端机上约 0.1ms，低端机约 0.5ms
    // 60fps 下每秒额外开销：高端机 12ms，低端机 60ms（相当于白白浪费 1 帧预算）
    private var aPositionLoc: Int = -1
    private var aTexCoordLoc: Int = -1

    // SurfaceTexture 变换矩阵（修正 OES 纹理方向）
    private val stMatrix = FloatArray(16)

    // ── 相机输入 SurfaceTexture ──────────────────────────────────────────────
    private var inputSurfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null

    // ── 当前相机 ID（用于切换专用 Shader）────────────────────────────────────
    @Volatile private var currentCameraId: String = ""

    // ── 渲染参数 ─────────────────────────────────────────────────────────────
    @Volatile private var contrast: Float = 1.0f
    @Volatile private var saturation: Float = 1.0f
    @Volatile private var temperatureShift: Float = 0.0f
    @Volatile private var chromaticAberration: Float = 0.0f
    @Volatile private var noiseAmount: Float = 0.0f
    @Volatile private var vignetteAmount: Float = 0.0f
    @Volatile private var grainAmount: Float = 0.0f
    @Volatile private var sharpen: Float = 0.0f
    @Volatile private var time: Float = 0.0f
    @Volatile private var fisheyeMode: Float = 0.0f // 0=normal, 1=circular fisheye
    // FQS/CPM35 专有参数
    @Volatile private var colorBiasR: Float = 0.0f
    @Volatile private var colorBiasG: Float = 0.0f
    @Volatile private var colorBiasB: Float = 0.0f
    @Volatile private var tintShift: Float = 0.0f
    @Volatile private var halationAmount: Float = 0.0f
    @Volatile private var bloomAmount: Float = 0.0f
    @Volatile private var grainSize: Float = 1.0f
    @Volatile private var luminanceNoise: Float = 0.0f
    @Volatile private var chromaNoise: Float = 0.0f
    // Inst C / SQC 共用参数
    @Volatile private var highlightRolloff: Float = 0.0f
    @Volatile private var paperTexture: Float = 0.0f
    @Volatile private var edgeFalloff: Float = 0.0f
    @Volatile private var exposureVariation: Float = 0.0f
    @Volatile private var cornerWarmShift: Float = 0.0f
    // 拍立得/数码通用参数（Inst C / SQC / FXN-R 共用）
    @Volatile private var centerGain: Float = 0.0f
    @Volatile private var developmentSoftness: Float = 0.0f
    @Volatile private var chemicalIrregularity: Float = 0.0f
    @Volatile private var skinHueProtect: Float = 0.0f
    @Volatile private var skinSatProtect: Float = 1.0f
    @Volatile private var skinLumaSoften: Float = 0.0f
    @Volatile private var skinRedLimit: Float = 1.0f
    // LUT + Tone Curve + Highlight Rolloff 参数
    @Volatile private var highlightRolloff2: Float = 0.0f
    @Volatile private var toneCurveStrength: Float = 0.0f
    @Volatile private var previewWidth: Int = 1280
    @Volatile private var previewHeight: Int = 720

    // ── 线程 ─────────────────────────────────────────────────────────────────
    private val glExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "CameraGLThread")
    }
    private val initialized = AtomicBoolean(false)

    // ── 初始化 ───────────────────────────────────────────────────────────────

    /**
     * 初始化 GL 渲染器并同步等待完成（最多 2 秒）
     * 必须从非 glExecutor 线程调用（否则会死锁）。
     */
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

        // ── 2. 选择 EGL config（支持 ES2/ES3 + Window Surface）──────────────
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
            // 降级到 ES 2.0
            Log.w(TAG, "ES3 context failed, trying ES2")
            val ctx2Attribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, ctx2Attribs, 0)
        }
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            Log.e(TAG, "eglCreateContext failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }

        // ── 4. 设置 Flutter SurfaceTexture 的缓冲区大小 ─────────────────────
        // 必须在 eglCreateWindowSurface 之前调用，否则 Surface 尺寸为 0
        flutterSurfaceTexture.setDefaultBufferSize(width, height)

        // ── 5. 创建 Window Surface（绑定到 Flutter SurfaceTexture）──────────
        // Surface(SurfaceTexture) 是合法的 EGL native window
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

        // ── 7. 编译着色器（根据 cameraId 选择专用 Shader）──────────────────
        val fragShader = when (currentCameraId) {
            "fqs"    -> FQSShaderSource.FRAGMENT_SHADER
            "cpm35"  -> CPM35ShaderSource.FRAGMENT_SHADER
            "inst_c" -> InstCShaderSource.FRAGMENT_SHADER
            else     -> FRAGMENT_SHADER
        }
        programId = createProgram(VERTEX_SHADER, fragShader)
        if (programId == 0) {
            Log.e(TAG, "Failed to create shader program")
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

        // ── 9. 创建 SurfaceTexture（相机帧输入）─────────────────────────────
        inputSurfaceTexture = SurfaceTexture(cameraTexId)
        inputSurfaceTexture!!.setDefaultBufferSize(width, height)
        inputSurfaceTexture!!.setOnFrameAvailableListener {
            // 每当相机有新帧时，在 GL 线程上渲染
            glExecutor.execute { renderFrame() }
        }
        inputSurface = Surface(inputSurfaceTexture)

        // ── 10. 获取 uniform 位置 ────────────────────────────────────────────
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
        uSTMatrix             = GLES30.glGetUniformLocation(programId, "uSTMatrix")
        uFisheyeMode          = GLES30.glGetUniformLocation(programId, "uFisheyeMode")
        uAspectRatio          = GLES30.glGetUniformLocation(programId, "uAspectRatio")
        // 性能优化：同时缓存 sampler 和 attrib 位置，避免 renderFrame 每帧查询
        uCameraTexture        = GLES30.glGetUniformLocation(programId, "uCameraTexture")
        aPositionLoc          = GLES30.glGetAttribLocation(programId, "aPosition")
        aTexCoordLoc          = GLES30.glGetAttribLocation(programId, "aTexCoord")
        // FQS/CPM35 专有 uniform（通用 Shader 中返回 -1，glUniform1f(-1,...) 是 no-op，安全）
        uColorBiasR           = GLES30.glGetUniformLocation(programId, "uColorBiasR")
        uColorBiasG           = GLES30.glGetUniformLocation(programId, "uColorBiasG")
        uColorBiasB           = GLES30.glGetUniformLocation(programId, "uColorBiasB")
        uTintShift            = GLES30.glGetUniformLocation(programId, "uTintShift")
        uHalationAmount       = GLES30.glGetUniformLocation(programId, "uHalationAmount")
        uBloomAmount          = GLES30.glGetUniformLocation(programId, "uBloomAmount")
        uGrainSize            = GLES30.glGetUniformLocation(programId, "uGrainSize")
        uLuminanceNoise       = GLES30.glGetUniformLocation(programId, "uLuminanceNoise")
        uChromaNoise          = GLES30.glGetUniformLocation(programId, "uChromaNoise")
        // Inst C / SQC 共用 uniform（其他 Shader 中返回 -1，传入无效果）
        uHighlightRolloff     = GLES30.glGetUniformLocation(programId, "uHighlightRolloff")
        uPaperTexture         = GLES30.glGetUniformLocation(programId, "uPaperTexture")
        uEdgeFalloff          = GLES30.glGetUniformLocation(programId, "uEdgeFalloff")
        uExposureVariation    = GLES30.glGetUniformLocation(programId, "uExposureVariation")
        uCornerWarmShift      = GLES30.glGetUniformLocation(programId, "uCornerWarmShift")
        // 拍立得/数码通用 uniform（Inst C / SQC / FXN-R 共用，其他 Shader 中 location=-1，传入无效果）
        uCenterGain           = GLES30.glGetUniformLocation(programId, "uCenterGain")
        uDevelopmentSoftness  = GLES30.glGetUniformLocation(programId, "uDevelopmentSoftness")
        uChemicalIrregularity = GLES30.glGetUniformLocation(programId, "uChemicalIrregularity")
        uSkinHueProtect       = GLES30.glGetUniformLocation(programId, "uSkinHueProtect")
        uSkinSatProtect       = GLES30.glGetUniformLocation(programId, "uSkinSatProtect")
        uSkinLumaSoften       = GLES30.glGetUniformLocation(programId, "uSkinLumaSoften")
        uSkinRedLimit         = GLES30.glGetUniformLocation(programId, "uSkinRedLimit")
        // LUT + Tone Curve + Highlight Rolloff
        uHighlightRolloff2    = GLES30.glGetUniformLocation(programId, "uHighlightRolloff2")
        uToneCurveStrength    = GLES30.glGetUniformLocation(programId, "uToneCurveStrength")

        // ── 11. 顶点缓冲 ─────────────────────────────────────────────────────
        vertexBuffer = ByteBuffer.allocateDirect(QUAD_VERTICES.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply { put(QUAD_VERTICES); position(0) }

        initialized.set(true)
        Log.d(TAG, "GL initialized successfully: ${width}x${height}")
    }

    // ── 渲染 ─────────────────────────────────────────────────────────────────

    private fun renderFrame() {
        if (!initialized.get()) return

        // 每帧都重新激活 EGL context（确保在 GL 线程上）
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            Log.w(TAG, "renderFrame: eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }

        // 更新相机帧纹理
        try {
            inputSurfaceTexture?.updateTexImage()
            // 获取 SurfaceTexture 变换矩阵（必须在 updateTexImage 后立即调用）
            inputSurfaceTexture?.getTransformMatrix(stMatrix)
        } catch (e: Exception) {
            Log.w(TAG, "updateTexImage failed: ${e.message}")
            return
        }

        GLES30.glViewport(0, 0, previewWidth, previewHeight)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        GLES30.glUseProgram(programId)

        // 绑定相机纹理（unit 0）
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexId)
        // 性能优化：使用初始化时缓存的 location，不再每帧调用 glGetUniformLocation
        GLES30.glUniform1i(uCameraTexture, 0)

        // 设置 uniform 参数
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
        GLES30.glUniform1f(uAspectRatio,         previewWidth.toFloat() / previewHeight.toFloat())
        // FQS/CPM35 专有 uniform（通用 Shader 中 location=-1，glUniform1f 是 no-op）
        GLES30.glUniform1f(uColorBiasR,          colorBiasR)
        GLES30.glUniform1f(uColorBiasG,          colorBiasG)
        GLES30.glUniform1f(uColorBiasB,          colorBiasB)
        GLES30.glUniform1f(uTintShift,           tintShift)
        GLES30.glUniform1f(uHalationAmount,      halationAmount)
        GLES30.glUniform1f(uBloomAmount,         bloomAmount)
        GLES30.glUniform1f(uGrainSize,           grainSize)
        GLES30.glUniform1f(uLuminanceNoise,      luminanceNoise)
        GLES30.glUniform1f(uChromaNoise,         chromaNoise)
        // Inst C / SQC 共用 uniform（其他 Shader 中 location=-1，glUniform1f 是 no-op）
        GLES30.glUniform1f(uHighlightRolloff,    highlightRolloff)
        GLES30.glUniform1f(uPaperTexture,        paperTexture)
        GLES30.glUniform1f(uEdgeFalloff,         edgeFalloff)
        GLES30.glUniform1f(uExposureVariation,   exposureVariation)
        GLES30.glUniform1f(uCornerWarmShift,     cornerWarmShift)
        // 拍立得/数码通用 uniform（Inst C / SQC / FXN-R 共用）
        GLES30.glUniform1f(uCenterGain,          centerGain)
        GLES30.glUniform1f(uDevelopmentSoftness, developmentSoftness)
        GLES30.glUniform1f(uChemicalIrregularity, chemicalIrregularity)
        GLES30.glUniform1f(uSkinHueProtect,      skinHueProtect)
        GLES30.glUniform1f(uSkinSatProtect,      skinSatProtect)
        GLES30.glUniform1f(uSkinLumaSoften,      skinLumaSoften)
        GLES30.glUniform1f(uSkinRedLimit,        skinRedLimit)
        // LUT + Tone Curve + Highlight Rolloff
        GLES30.glUniform1f(uHighlightRolloff2,   highlightRolloff2)
        GLES30.glUniform1f(uToneCurveStrength,   toneCurveStrength)
        // 传入 SurfaceTexture 变换矩阵（修正 OES 纹理方向）
        GLES30.glUniformMatrix4fv(uSTMatrix, 1, false, stMatrix, 0)
        time += 0.016f

        // 顶点属性：使用初始化时缓存的 attrib location（关键热路径优化）
        // 原来每帧调用 glGetAttribLocation 是同步 GPU driver 查询，已全部消除
        val vb = vertexBuffer ?: return
        val stride = 4 * 4 // 4 floats * 4 bytes

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
        (params["contrast"]            as? Number)?.let { contrast            = it.toFloat() }
        (params["saturation"]          as? Number)?.let { saturation          = it.toFloat() }
        (params["temperatureShift"]    as? Number)?.let { temperatureShift    = it.toFloat() }
        (params["chromaticAberration"] as? Number)?.let { chromaticAberration = it.toFloat() }
        (params["noise"]               as? Number)?.let { noiseAmount         = it.toFloat() }
        (params["vignette"]            as? Number)?.let { vignetteAmount      = it.toFloat() }
        (params["grain"]               as? Number)?.let { grainAmount         = it.toFloat() }
        (params["sharpen"]             as? Number)?.let { sharpen             = it.toFloat() }
        // FQS/CPM35 专有参数
        (params["colorBiasR"]          as? Number)?.let { colorBiasR          = it.toFloat() }
        (params["colorBiasG"]          as? Number)?.let { colorBiasG          = it.toFloat() }
        (params["colorBiasB"]          as? Number)?.let { colorBiasB          = it.toFloat() }
        (params["tintShift"]           as? Number)?.let { tintShift           = it.toFloat() }
        (params["halationAmount"]      as? Number)?.let { halationAmount      = it.toFloat() }
        (params["bloomAmount"]         as? Number)?.let { bloomAmount         = it.toFloat() }
        (params["grainSize"]           as? Number)?.let { grainSize           = it.toFloat() }
        (params["luminanceNoise"]      as? Number)?.let { luminanceNoise      = it.toFloat() }
        (params["chromaNoise"]         as? Number)?.let { chromaNoise         = it.toFloat() }
        // Inst C / SQC 共用参数
        (params["highlightRolloff"]    as? Number)?.let { highlightRolloff    = it.toFloat() }
        (params["paperTexture"]        as? Number)?.let { paperTexture        = it.toFloat() }
        (params["edgeFalloff"]         as? Number)?.let { edgeFalloff         = it.toFloat() }
        (params["exposureVariation"]   as? Number)?.let { exposureVariation   = it.toFloat() }
        (params["cornerWarmShift"]     as? Number)?.let { cornerWarmShift     = it.toFloat() }
        // 拍立得/数码通用参数（Inst C / SQC / FXN-R 共用）
        (params["centerGain"]          as? Number)?.let { centerGain          = it.toFloat() }
        (params["developmentSoftness"] as? Number)?.let { developmentSoftness = it.toFloat() }
        (params["chemicalIrregularity"] as? Number)?.let { chemicalIrregularity = it.toFloat() }
        (params["skinHueProtect"]      as? Number)?.let { skinHueProtect      = it.toFloat() }
        (params["skinSatProtect"]      as? Number)?.let { skinSatProtect      = it.toFloat() }
        (params["skinLumaSoften"]      as? Number)?.let { skinLumaSoften      = it.toFloat() }
        (params["skinRedLimit"]        as? Number)?.let { skinRedLimit        = it.toFloat() }
        // LUT + Tone Curve + Highlight Rolloff
        (params["highlightRolloff"]     as? Number)?.let { highlightRolloff2    = it.toFloat() }
        (params["toneCurveStrength"]    as? Number)?.let { toneCurveStrength    = it.toFloat() }
    }

    /**
     * 切换相机 ID，重新编译对应的专用 Fragment Shader（FQS/CPM35/通用）。
     * 必须在 GL 线程上执行（通过 glExecutor 调度），因为需要操作 GL 资源。
     * 调用后下一帧自动使用新 Shader。
     */
    fun setCameraId(cameraId: String) {
        if (currentCameraId == cameraId) return // 同一相机无需重编译
        currentCameraId = cameraId
        if (!initialized.get()) return // 未初始化时只记录 ID，initialize() 会用正确的 Shader
        glExecutor.execute {
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) return@execute
            // 删除旧 program
            if (programId != 0) {
                GLES30.glDeleteProgram(programId)
                programId = 0
            }
            // 编译新 Shader
            val fragShader = when (cameraId) {
                "fqs"    -> FQSShaderSource.FRAGMENT_SHADER
                "cpm35"  -> CPM35ShaderSource.FRAGMENT_SHADER
                "inst_c" -> InstCShaderSource.FRAGMENT_SHADER
                "sqc"    -> SQCGLRenderer.FRAGMENT_SHADER
                "grd_r"  -> GRDRGLRenderer.FRAGMENT_SHADER
                "u300"   -> U300GLRenderer.FRAGMENT_SHADER
                "ccd_r"  -> CCDRGLRenderer.FRAGMENT_SHADER
                "bw_classic" -> BWClassicGLRenderer.FRAGMENT_SHADER
                else     -> FRAGMENT_SHADER
            }
            programId = createProgram(VERTEX_SHADER, fragShader)
            if (programId == 0) {
                Log.e(TAG, "setCameraId: failed to recompile shader for cameraId=$cameraId")
                return@execute
            }
            // 重新缓存 uniform 位置
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
            uSTMatrix             = GLES30.glGetUniformLocation(programId, "uSTMatrix")
            uFisheyeMode          = GLES30.glGetUniformLocation(programId, "uFisheyeMode")
            uAspectRatio          = GLES30.glGetUniformLocation(programId, "uAspectRatio")
            uCameraTexture        = GLES30.glGetUniformLocation(programId, "uCameraTexture")
            aPositionLoc          = GLES30.glGetAttribLocation(programId, "aPosition")
            aTexCoordLoc          = GLES30.glGetAttribLocation(programId, "aTexCoord")
            uColorBiasR           = GLES30.glGetUniformLocation(programId, "uColorBiasR")
            uColorBiasG           = GLES30.glGetUniformLocation(programId, "uColorBiasG")
            uColorBiasB           = GLES30.glGetUniformLocation(programId, "uColorBiasB")
            uTintShift            = GLES30.glGetUniformLocation(programId, "uTintShift")
            uHalationAmount       = GLES30.glGetUniformLocation(programId, "uHalationAmount")
            uBloomAmount          = GLES30.glGetUniformLocation(programId, "uBloomAmount")
            uGrainSize            = GLES30.glGetUniformLocation(programId, "uGrainSize")
            uLuminanceNoise       = GLES30.glGetUniformLocation(programId, "uLuminanceNoise")
            uChromaNoise          = GLES30.glGetUniformLocation(programId, "uChromaNoise")
            // Inst C / SQC 共用 uniform
            uHighlightRolloff     = GLES30.glGetUniformLocation(programId, "uHighlightRolloff")
            uPaperTexture         = GLES30.glGetUniformLocation(programId, "uPaperTexture")
            uEdgeFalloff          = GLES30.glGetUniformLocation(programId, "uEdgeFalloff")
            uExposureVariation    = GLES30.glGetUniformLocation(programId, "uExposureVariation")
            uCornerWarmShift      = GLES30.glGetUniformLocation(programId, "uCornerWarmShift")
            // 拍立得/数码通用 uniform（Inst C / SQC / FXN-R 共用）
            uCenterGain           = GLES30.glGetUniformLocation(programId, "uCenterGain")
            uDevelopmentSoftness  = GLES30.glGetUniformLocation(programId, "uDevelopmentSoftness")
            uChemicalIrregularity = GLES30.glGetUniformLocation(programId, "uChemicalIrregularity")
            uSkinHueProtect       = GLES30.glGetUniformLocation(programId, "uSkinHueProtect")
            uSkinSatProtect       = GLES30.glGetUniformLocation(programId, "uSkinSatProtect")
            uSkinLumaSoften       = GLES30.glGetUniformLocation(programId, "uSkinLumaSoften")
            uSkinRedLimit         = GLES30.glGetUniformLocation(programId, "uSkinRedLimit")
            uHighlightRolloff2    = GLES30.glGetUniformLocation(programId, "uHighlightRolloff2")
            uToneCurveStrength    = GLES30.glGetUniformLocation(programId, "uToneCurveStrength")
            Log.d(TAG, "setCameraId: shader recompiled for cameraId=$cameraId")
        }
    }

    fun setSharpen(level: Float) {
        sharpen = level
    }

    fun setFisheyeMode(enabled: Boolean) {
        fisheyeMode = if (enabled) 1.0f else 0.0f
    }

    // ── 获取相机输入 Surface ──────────────────────────────────────────────────

    /**
     * 返回 CameraX Preview 应该渲染到的 Surface。
     * 必须在 initialize() 完成后调用。
     */
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
