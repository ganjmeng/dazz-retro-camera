package com.retrocam.app.utils

import android.opengl.GLES20

object GLUtils {

    const val VERTEX_SHADER = """
        attribute vec4 aPosition;
        varying vec2 vTexCoord;
        void main() {
            gl_Position = aPosition;
            vTexCoord = aPosition.xy * 0.5 + 0.5;
        }
    """

    const val FRAGMENT_SHADER_CCD = """
        #extension GL_OES_EGL_image_external : require
        precision mediump float;
        uniform samplerExternalOES uCameraTexture;
        uniform float uContrast;
        uniform float uSaturation;
        uniform float uTemperatureShift;
        uniform float uTintShift;
        uniform float uHighlights;
        uniform float uShadows;
        uniform float uWhites;
        uniform float uBlacks;
        uniform float uClarity;
        uniform float uVibrance;
        uniform float uColorBiasR;
        uniform float uColorBiasG;
        uniform float uColorBiasB;
        uniform float uGrainAmount;
        uniform float uNoiseAmount;
        uniform float uVignetteAmount;
        uniform float uChromaticAberration;
        uniform float uBloomAmount;
        uniform float uTime;
        uniform float uDistortion;
        uniform float uZoomFactor;
        uniform float uLensVignette;
        varying vec2 vTexCoord;

        // ... (所有 GLSL 工具函数和 main 函数) ...

        void main() {
            vec2 uv = vTexCoord;
            // 1. 镜头畸变和缩放
            vec2 d = uv - 0.5;
            float r2 = d.x * d.x + d.y * d.y;
            uv = 0.5 + (d * (1.0 + uDistortion * r2)) / uZoomFactor;

            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
                gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
                return;
            }

            vec4 color = texture2D(uCameraTexture, uv);
            // ... (所有 Pass 的调用) ...
            gl_FragColor = color;
        }
    """

    fun loadShader(type: Int, shaderCode: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, shaderCode)
        GLES20.glCompileShader(shader)
        return shader
    }
}
