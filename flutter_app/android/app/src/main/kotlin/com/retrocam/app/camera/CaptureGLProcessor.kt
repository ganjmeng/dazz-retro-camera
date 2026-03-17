package com.retrocam.app.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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

// ── 工具函数 ──────────────────────────────────────────────────────────

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

// ── Pass 1: 色差 ──────────────────────────────────────────────────────
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
    c.r = clamp(c.r + shift * 0.1, 0.0, 1.0);
    c.b = clamp(c.b - shift * 0.1, 0.0, 1.0);
    return c;
}

vec3 applyTint(vec3 c, float shift) {
    c.g = clamp(c.g + shift * 0.05, 0.0, 1.0);
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
    return clamp(c + vec3(r, g, b) * 0.1, 0.0, 1.0);
}

// ── Pass 9: Bloom ─────────────────────────────────────────────────────
vec3 applyBloom(vec3 c, float amount) {
    if (amount < 0.001) return c;
    float lum = luminance(c);
    if (lum > 0.75) {
        float bloom = clamp((lum - 0.75) * amount * 2.5, 0.0, 0.25);
        c.r = clamp(c.r + bloom * 0.9, 0.0, 1.0);
        c.g = clamp(c.g + bloom * 0.8, 0.0, 1.0);
        c.b = clamp(c.b + bloom * 0.6, 0.0, 1.0);
    }
    return c;
}

// ── Pass 10: Halation（高光辉光）─────────────────────────────────────
vec3 applyHalation(vec3 c, float amount) {
    if (amount < 0.001) return c;
    float lum = luminance(c);
    float mask = smoothstep(0.6, 1.0, lum);
    c.r = clamp(c.r + mask * amount * 0.3, 0.0, 1.0);
    c.g = clamp(c.g + mask * amount * 0.05, 0.0, 1.0);
    c.b = clamp(c.b - mask * amount * 0.05, 0.0, 1.0);
    return c;
}

// ── Pass 11: Highlight Rolloff ────────────────────────────────────────
vec3 applyHighlightRolloff(vec3 c, float rolloff) {
    if (rolloff < 0.001) return c;
    float lum = luminance(c);
    float mask = smoothstep(0.7, 1.0, lum);
    float compress = 1.0 - mask * rolloff * 0.3;
    return clamp(c * compress + vec3(mask * rolloff * 0.05), 0.0, 1.0);
}

// ── Pass 12: Center Gain ──────────────────────────────────────────────
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

// ── Pass 17: Film Grain ───────────────────────────────────────────────
vec3 applyGrain(vec3 c, vec2 uv, float amount, float time) {
    if (amount < 0.001) return c;
    float grain = hash(uv + vec2(time * 0.1, time * 0.13)) * 2.0 - 1.0;
    return clamp(c + vec3(grain * amount), 0.0, 1.0);
}

// ── Pass 18: Digital Noise ────────────────────────────────────────────
vec3 applyNoise(vec3 c, vec2 uv, float amount, float time) {
    if (amount < 0.001) return c;
    float n = hash(uv * 3.7 + vec2(time * 0.17, time * 0.23)) * 2.0 - 1.0;
    return clamp(c + vec3(n * amount * 0.5), 0.0, 1.0);
}

// ── Pass 19: Vignette ─────────────────────────────────────────────────
vec3 applyVignette(vec3 c, vec2 uv, float amount) {
    if (amount < 0.001) return c;
    float dist = length(uv - 0.5) * 1.414;
    float vignette = 1.0 - smoothstep(0.5, 1.4, dist) * amount;
    return clamp(c * vignette, 0.0, 1.0);
}

// ── 主函数 ────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;

    // Pass 1: 色差
    vec3 color = applyChromaticAberration(uInputTexture, uv, uChromaticAberration);

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

    // Pass 9: Bloom
    color = applyBloom(color, uBloomAmount);

    // Pass 10: Halation
    color = applyHalation(color, uHalationAmount);

    // Pass 11: Highlight Rolloff（成片专属）
    color = applyHighlightRolloff(color, uHighlightRolloff);

    // Pass 12: Center Gain（成片专属）
    color = applyCenterGain(color, uv, uCenterGain);

    // Pass 13: 肤色保护（成片专属）
    color = applySkinProtect(color, uSkinHueProtect, uSkinSatProtect, uSkinLumaSoften, uSkinRedLimit);

    // Pass 14: Edge Falloff + Corner Warm（成片专属）
    color = applyEdgeFalloff(color, uv, uEdgeFalloff);
    color = applyCornerWarm(color, uv, uCornerWarmShift);

    // Pass 15: Chemical Irregularity（成片专属）
    color = applyChemicalIrregularity(color, uv, uChemicalIrregularity, uTime);

    // Pass 16: Paper Texture（成片专属）
    color = applyPaperTexture(color, uv, uPaperTexture, uTime);

    // Pass 17: Film Grain
    color = applyGrain(color, uv, uGrainAmount, uTime);

    // Pass 18: Digital Noise
    color = applyNoise(color, uv, uNoiseAmount, uTime);

    // Pass 19: Vignette
    float vigTotal = min(uVignetteAmount + uLensVignette, 1.0);
    color = applyVignette(color, uv, vigTotal);

    fragColor = vec4(color, 1.0);
}"""

        // 全屏四边形顶点数据（位置 + UV）
        private val QUAD_VERTICES = floatArrayOf(
            // x,    y,    u,    v
            -1.0f, -1.0f, 0.0f, 0.0f,
             1.0f, -1.0f, 1.0f, 0.0f,
            -1.0f,  1.0f, 0.0f, 1.0f,
             1.0f,  1.0f, 1.0f, 1.0f,
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
            val inBitmap = BitmapFactory.decodeFile(filePath, options)
                ?: return null.also { Log.e(TAG, "Failed to decode: $filePath") }

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

            // 5. 回读像素
            val pixelBuf = ByteBuffer.allocateDirect(width * height * 4).apply {
                order(ByteOrder.nativeOrder())
            }
            GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, pixelBuf)
            pixelBuf.rewind()

            // 6. 释放临时纹理
            GLES30.glDeleteTextures(1, intArrayOf(inputTex), 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

            // 7. 将像素写入 Bitmap（注意 GL 坐标系 Y 轴翻转）
            val outBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val flipped = flipVertically(pixelBuf, width, height)
            outBitmap.copyPixelsFromBuffer(flipped)

            // 8. 编码为 JPEG
            val outputFile = File(context.cacheDir, "gpu_${File(filePath).name}")
            FileOutputStream(outputFile).use { fos ->
                outBitmap.compress(Bitmap.CompressFormat.JPEG, 92, fos)
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
