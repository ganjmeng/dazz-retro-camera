package com.retrocam.app.camera

import android.content.Context
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
 * CameraGLRenderer
 *
 * 完整的 EGL + OpenGL ES 3.0 渲染管线：
 *   CameraX Preview → inputSurfaceTexture (GL_TEXTURE_EXTERNAL_OES)
 *     → 片段着色器（色差 / 对比度 / 饱和度 / 颗粒 / 暗角 / Unsharp Mask 锐化）
 *     → Flutter SurfaceTexture（输出）
 *
 * 所有 GL 调用必须在同一个 EGL 线程上执行。
 */
class CameraGLRenderer(
    private val context: Context,
    private val flutterSurfaceTexture: SurfaceTexture
) {
    companion object {
        private const val TAG = "CameraGLRenderer"

        // ── 顶点着色器 ──────────────────────────────────────────────────────────
        private const val VERTEX_SHADER = """
            #version 300 es
            in vec4 aPosition;
            in vec2 aTexCoord;
            out vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord   = aTexCoord;
            }
        """

        // ── 片段着色器（OES 外部纹理 + CCD 效果 + Unsharp Mask 锐化）──────────
        private const val FRAGMENT_SHADER = """
            #version 300 es
            #extension GL_OES_EGL_image_external_essl3 : require
            precision mediump float;

            in  vec2 vTexCoord;
            out vec4 fragColor;

            uniform samplerExternalOES uCameraTexture;
            uniform sampler2D          uGrainTexture;

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

            // ── 工具函数 ──────────────────────────────────────────────────────
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
                c.r = clamp(c.r - s * 0.3, 0.0, 1.0);
                c.b = clamp(c.b + s * 0.3, 0.0, 1.0);
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

            // ── 主函数 ────────────────────────────────────────────────────────
            void main() {
                vec2 uv = vTexCoord;

                // Pass 0: 锐化 (Unsharp Mask)
                vec3 color = applySharpen(uv, uSharpen);

                // Pass 1: 色差 (Chromatic Aberration)
                if (uChromaticAberration > 0.0) {
                    float ca = uChromaticAberration;
                    float r = texture(uCameraTexture, uv + vec2(ca, 0.0)).r;
                    float g = texture(uCameraTexture, uv).g;
                    float b = texture(uCameraTexture, uv - vec2(ca, 0.0)).b;
                    color = vec3(r, g, b);
                }

                // Pass 2: 基础色彩调整
                color = applyTemperature(color, uTemperatureShift);
                color = applyContrast(color, uContrast);
                color = applySaturation(color, uSaturation);

                // Pass 3: 胶片颗粒
                if (uGrainAmount > 0.0) {
                    vec3 grain = texture(uGrainTexture, uv * 2.0).rgb;
                    color = clamp(color + (grain - 0.5) * uGrainAmount * 0.3, 0.0, 1.0);
                }

                // Pass 4: 动态数字噪点
                if (uNoiseAmount > 0.0) {
                    float lum   = dot(color, vec3(0.2126, 0.7152, 0.0722));
                    float noise = random(uv, uTime) - 0.5;
                    float dark  = 1.0 - lum;
                    color = clamp(color + noise * uNoiseAmount * 0.2 * dark, 0.0, 1.0);
                }

                // Pass 5: 暗角
                float vignette = vignetteEffect(uv, uVignetteAmount);
                color *= vignette;

                fragColor = vec4(color, 1.0);
            }
        """

        // 全屏四边形顶点（位置 + UV）
        private val QUAD_VERTICES = floatArrayOf(
            -1f,  1f,  0f, 0f,   // 左上
            -1f, -1f,  0f, 1f,   // 左下
             1f,  1f,  1f, 0f,   // 右上
             1f, -1f,  1f, 1f    // 右下
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

    // Uniform 位置
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

    // ── 相机输入 SurfaceTexture ──────────────────────────────────────────────
    private var inputSurfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null

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
    @Volatile private var previewWidth: Int = 1280
    @Volatile private var previewHeight: Int = 720

    // ── 线程 ─────────────────────────────────────────────────────────────────
    private val glExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "CameraGLThread")
    }
    private val initialized = AtomicBoolean(false)
    private val frameAvailable = AtomicBoolean(false)
    private var initLatch: CountDownLatch? = null

    // ── 初始化 ───────────────────────────────────────────────────────────────

    /**
     * 初始化 GL 渲染器并同步等待完成（最多 1 秒）
     * 可在任意线程上调用。
     */
    fun initialize(width: Int, height: Int) {
        previewWidth = width
        previewHeight = height
        val latch = CountDownLatch(1)
        initLatch = latch
        glExecutor.execute {
            initGL(width, height)
            latch.countDown()
        }
        // 在调用线程上等待（最多 1 秒）
        latch.await(1, TimeUnit.SECONDS)
    }

    private fun initGL(width: Int, height: Int) {
        // 1. 获取 EGL display
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
            Log.e(TAG, "eglGetDisplay failed")
            return
        }
        val version = IntArray(2)
        EGL14.eglInitialize(eglDisplay, version, 0, version, 1)

        // 2. 选择 EGL config
        val attribList = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, 1, numConfigs, 0)
        val config = configs[0] ?: run {
            Log.e(TAG, "eglChooseConfig failed")
            return
        }

        // 3. 创建 EGL context（ES 3.0）
        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)

        // 4. 创建 Window Surface（绑定到 Flutter SurfaceTexture）
        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        val flutterSurface = Surface(flutterSurfaceTexture)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, flutterSurface, surfaceAttribs, 0)

        // 5. 激活 EGL context
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        // 6. 编译着色器
        programId = createProgram(VERTEX_SHADER.trimIndent(), FRAGMENT_SHADER.trimIndent())
        if (programId == 0) {
            Log.e(TAG, "Failed to create shader program")
            return
        }

        // 7. 创建相机输入纹理（OES 外部纹理）
        val texIds = IntArray(1)
        GLES30.glGenTextures(1, texIds, 0)
        cameraTexId = texIds[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        // 8. 创建 SurfaceTexture（相机帧输入）
        inputSurfaceTexture = SurfaceTexture(cameraTexId)
        inputSurfaceTexture!!.setDefaultBufferSize(width, height)
        inputSurfaceTexture!!.setOnFrameAvailableListener {
            frameAvailable.set(true)
            glExecutor.execute { renderFrame() }
        }
        inputSurface = Surface(inputSurfaceTexture)

        // 9. 获取 uniform 位置
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

        // 10. 顶点缓冲
        vertexBuffer = ByteBuffer.allocateDirect(QUAD_VERTICES.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply { put(QUAD_VERTICES); position(0) }

        initialized.set(true)
        Log.d(TAG, "GL initialized: ${width}x${height}")
    }

    // ── 渲染 ─────────────────────────────────────────────────────────────────

    private fun renderFrame() {
        if (!initialized.get()) return
        if (!frameAvailable.getAndSet(false)) return

        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        // 更新相机帧纹理
        inputSurfaceTexture?.updateTexImage()

        GLES30.glViewport(0, 0, previewWidth, previewHeight)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        GLES30.glUseProgram(programId)

        // 绑定相机纹理
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexId)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(programId, "uCameraTexture"), 0)

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
        time += 0.016f

        // 顶点属性
        val vb = vertexBuffer ?: return
        vb.position(0)
        val stride = 4 * 4 // 4 floats * 4 bytes
        val posLoc = GLES30.glGetAttribLocation(programId, "aPosition")
        val texLoc = GLES30.glGetAttribLocation(programId, "aTexCoord")
        GLES30.glEnableVertexAttribArray(posLoc)
        GLES30.glEnableVertexAttribArray(texLoc)
        vb.position(0)
        GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, stride, vb)
        vb.position(2)
        GLES30.glVertexAttribPointer(texLoc, 2, GLES30.GL_FLOAT, false, stride, vb)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(posLoc)
        GLES30.glDisableVertexAttribArray(texLoc)

        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
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
    }

    fun setSharpen(level: Float) {
        sharpen = level
    }

    // ── 获取相机输入 Surface ──────────────────────────────────────────────────

    /**
     * 返回 CameraX Preview 应该渲染到的 Surface。
     * 必须在 initialize() 完成后调用。
     */
    fun getInputSurface(): Surface? = inputSurface

    // ── 释放 ─────────────────────────────────────────────────────────────────

    fun release() {
        glExecutor.execute {
            inputSurface?.release()
            inputSurfaceTexture?.release()
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroySurface(eglDisplay, eglSurface)
                EGL14.eglDestroyContext(eglDisplay, eglContext)
                EGL14.eglTerminate(eglDisplay)
            }
            initialized.set(false)
        }
        glExecutor.shutdown()
    }

    // ── 着色器编译工具 ────────────────────────────────────────────────────────

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == GLES30.GL_FALSE) {
            Log.e(TAG, "Shader compile error: ${GLES30.glGetShaderInfoLog(shader)}")
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
