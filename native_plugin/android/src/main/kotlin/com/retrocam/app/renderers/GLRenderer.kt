package com.retrocam.app.renderers

import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLES30
import android.view.Surface
import com.retrocam.app.utils.GLUtils
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Manages OpenGL ES rendering pipeline.
 * Takes camera frames via SurfaceTexture, applies shaders, and outputs to Flutter's SurfaceTexture.
 */
class GLRenderer(private val flutterSurfaceTexture: SurfaceTexture) {

    private var inputSurfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null

    private var programId = -1
    private var vertexBuffer: FloatBuffer? = null

    // ── Uniform Locations ───────────────────────────────────────────────────
    private var uContrastLoc = -1
    private var uSaturationLoc = -1
    private var uTemperatureShiftLoc = -1
    private var uTintShiftLoc = -1
    private var uHighlightsLoc = -1
    private var uShadowsLoc = -1
    private var uWhitesLoc = -1
    private var uBlacksLoc = -1
    private var uClarityLoc = -1
    private var uVibranceLoc = -1
    private var uColorBiasRLoc = -1
    private var uColorBiasGLoc = -1
    private var uColorBiasBLoc = -1
    private var uGrainAmountLoc = -1
    private var uNoiseAmountLoc = -1
    private var uVignetteAmountLoc = -1
    private var uChromaticAberrationLoc = -1
    private var uBloomAmountLoc = -1
    private var uTimeLoc = -1
    private var uDistortionLoc = -1
    private var uZoomFactorLoc = -1
    private var uLensVignetteLoc = -1

    // ── Shader Parameters ───────────────────────────────────────────────────
    private var contrast = 1.0f
    private var saturation = 1.0f
    private var temperatureShift = 0.0f
    private var tintShift = 0.0f
    private var highlights = 0.0f
    private var shadows = 0.0f
    private var whites = 0.0f
    private var blacks = 0.0f
    private var clarity = 0.0f
    private var vibrance = 0.0f
    private var colorBiasR = 0.0f
    private var colorBiasG = 0.0f
    private var colorBiasB = 0.0f
    private var grainAmount = 0.0f
    private var noiseAmount = 0.0f
    private var vignetteAmount = 0.0f
    private var chromaticAberration = 0.0f
    private var bloomAmount = 0.0f
    private var time = 0.0f
    private var distortion = 0.0f
    private var zoomFactor = 1.0f
    private var lensVignette = 0.0f

    init {
        // This would run on a dedicated GL thread
        // setupEGL()
        setupShaders()
        setupGeometry()

        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val inputTexId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, inputTexId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        inputSurfaceTexture = SurfaceTexture(inputTexId)
        inputSurfaceTexture?.setOnFrameAvailableListener { onFrameAvailable() }
        inputSurface = Surface(inputSurfaceTexture)
    }

    private fun setupShaders() {
        val vertexShader = GLUtils.loadShader(GLES20.GL_VERTEX_SHADER, GLUtils.VERTEX_SHADER)
        val fragmentShader = GLUtils.loadShader(GLES20.GL_FRAGMENT_SHADER, GLUtils.FRAGMENT_SHADER_CCD)
        programId = GLES20.glCreateProgram()
        GLES20.glAttachShader(programId, vertexShader)
        GLES20.glAttachShader(programId, fragmentShader)
        GLES20.glLinkProgram(programId)
        GLES20.glUseProgram(programId)
        getUniformLocations()
    }

    private fun getUniformLocations() {
        uContrastLoc = GLES20.glGetUniformLocation(programId, "uContrast")
        uSaturationLoc = GLES20.glGetUniformLocation(programId, "uSaturation")
        uTemperatureShiftLoc = GLES20.glGetUniformLocation(programId, "uTemperatureShift")
        uTintShiftLoc = GLES20.glGetUniformLocation(programId, "uTintShift")
        uHighlightsLoc = GLES20.glGetUniformLocation(programId, "uHighlights")
        uShadowsLoc = GLES20.glGetUniformLocation(programId, "uShadows")
        uWhitesLoc = GLES20.glGetUniformLocation(programId, "uWhites")
        uBlacksLoc = GLES20.glGetUniformLocation(programId, "uBlacks")
        uClarityLoc = GLES20.glGetUniformLocation(programId, "uClarity")
        uVibranceLoc = GLES20.glGetUniformLocation(programId, "uVibrance")
        uColorBiasRLoc = GLES20.glGetUniformLocation(programId, "uColorBiasR")
        uColorBiasGLoc = GLES20.glGetUniformLocation(programId, "uColorBiasG")
        uColorBiasBLoc = GLES20.glGetUniformLocation(programId, "uColorBiasB")
        uGrainAmountLoc = GLES20.glGetUniformLocation(programId, "uGrainAmount")
        uNoiseAmountLoc = GLES20.glGetUniformLocation(programId, "uNoiseAmount")
        uVignetteAmountLoc = GLES20.glGetUniformLocation(programId, "uVignetteAmount")
        uChromaticAberrationLoc = GLES20.glGetUniformLocation(programId, "uChromaticAberration")
        uBloomAmountLoc = GLES20.glGetUniformLocation(programId, "uBloomAmount")
        uTimeLoc = GLES20.glGetUniformLocation(programId, "uTime")
        uDistortionLoc = GLES20.glGetUniformLocation(programId, "uDistortion")
        uZoomFactorLoc = GLES20.glGetUniformLocation(programId, "uZoomFactor")
        uLensVignetteLoc = GLES20.glGetUniformLocation(programId, "uLensVignette")
    }

    private fun setupGeometry() {
        val vertices = floatArrayOf(-1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f)
        vertexBuffer = ByteBuffer.allocateDirect(vertices.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
        vertexBuffer?.put(vertices)?.position(0)
    }

    fun updateParams(params: Map<String, Any>) {
        (params["contrast"] as? Number)?.let { contrast = it.toFloat() }
        (params["saturation"] as? Number)?.let { saturation = it.toFloat() }
        (params["temperatureShift"] as? Number)?.let { temperatureShift = it.toFloat() }
        (params["tintShift"] as? Number)?.let { tintShift = it.toFloat() }
        (params["highlights"] as? Number)?.let { highlights = it.toFloat() }
        (params["shadows"] as? Number)?.let { shadows = it.toFloat() }
        (params["whites"] as? Number)?.let { whites = it.toFloat() }
        (params["blacks"] as? Number)?.let { blacks = it.toFloat() }
        (params["clarity"] as? Number)?.let { clarity = it.toFloat() }
        (params["vibrance"] as? Number)?.let { vibrance = it.toFloat() }
        @Suppress("UNCHECKED_CAST")
        (params["colorBias"] as? Map<String, Any>)?.let {
            (it["r"] as? Number)?.let { colorBiasR = it.toFloat() }
            (it["g"] as? Number)?.let { colorBiasG = it.toFloat() }
            (it["b"] as? Number)?.let { colorBiasB = it.toFloat() }
        }
        (params["chromaticAberration"] as? Number)?.let { chromaticAberration = it.toFloat() }
        (params["noise"] as? Number)?.let { noiseAmount = it.toFloat() }
        (params["vignette"] as? Number)?.let { vignetteAmount = it.toFloat() }
        (params["bloom"] as? Number)?.let { bloomAmount = it.toFloat() }
        (params["grain"] as? Number)?.let { grainAmount = it.toFloat() }
        (params["distortion"] as? Number)?.let { distortion = it.toFloat() }
        (params["zoomFactor"] as? Number)?.let { zoomFactor = it.toFloat() }
        (params["lensVignette"] as? Number)?.let { lensVignette = it.toFloat() }
    }

    fun getInputSurface(): Surface = inputSurface!!

    private fun onFrameAvailable() {
        inputSurfaceTexture?.updateTexImage()

        // This would be part of the EGL setup, binding the Flutter surface
        // GLES20.glViewport(0, 0, width, height)
        // GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glUseProgram(programId)

        val positionHandle = GLES20.glGetAttribLocation(programId, "aPosition")
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)

        time += 0.016f
        updateUniforms()

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(positionHandle)
        // eglSwapBuffers(eglDisplay, eglSurface)
    }

    private fun updateUniforms() {
        GLES20.glUniform1f(uContrastLoc, contrast)
        GLES20.glUniform1f(uSaturationLoc, saturation)
        GLES20.glUniform1f(uTemperatureShiftLoc, temperatureShift)
        GLES20.glUniform1f(uTintShiftLoc, tintShift)
        GLES20.glUniform1f(uHighlightsLoc, highlights)
        GLES20.glUniform1f(uShadowsLoc, shadows)
        GLES20.glUniform1f(uWhitesLoc, whites)
        GLES20.glUniform1f(uBlacksLoc, blacks)
        GLES20.glUniform1f(uClarityLoc, clarity)
        GLES20.glUniform1f(uVibranceLoc, vibrance)
        GLES20.glUniform1f(uColorBiasRLoc, colorBiasR)
        GLES20.glUniform1f(uColorBiasGLoc, colorBiasG)
        GLES20.glUniform1f(uColorBiasBLoc, colorBiasB)
        GLES20.glUniform1f(uGrainAmountLoc, grainAmount)
        GLES20.glUniform1f(uNoiseAmountLoc, noiseAmount)
        GLES20.glUniform1f(uVignetteAmountLoc, vignetteAmount)
        GLES20.glUniform1f(uChromaticAberrationLoc, chromaticAberration)
        GLES20.glUniform1f(uBloomAmountLoc, bloomAmount)
        GLES20.glUniform1f(uTimeLoc, time)
        GLES20.glUniform1f(uDistortionLoc, distortion)
        GLES20.glUniform1f(uZoomFactorLoc, zoomFactor)
        GLES20.glUniform1f(uLensVignetteLoc, lensVignette)
    }

    fun release() {
        inputSurface?.release()
        inputSurfaceTexture?.release()
        GLES20.glDeleteProgram(programId)
    }
}
