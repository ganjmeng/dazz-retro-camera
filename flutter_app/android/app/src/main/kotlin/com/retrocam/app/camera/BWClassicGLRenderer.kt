package com.retrocam.app.camera

/**
 * BWClassicGLRenderer — BW Classic (Kodak Tri-X 400 / Ilford HP5 Plus) GLSL Shader
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 风格定位：
 *   Kodak Tri-X 400 / Ilford HP5 Plus（35mm 黑白胶片，高对比经典）
 *   核心气质：深黑 + 高对比 + 粗颗粒 + 银盐光晕 + 真实胶片层次
 *
 * 核心特征（基于 Kodak Tri-X 400 真实感光特性）：
 *   1. 黑白混合通道权重（Channel Mixer）
 *      bwChannelR=0.22（红色权重偏低，肤色偏暗，Tri-X 特征）
 *      bwChannelG=0.72（绿色权重偏高，主要亮度来源）
 *      bwChannelB=0.06（蓝色权重偏低，天空深暗，云彩对比强）
 *   2. 高对比（contrast=1.28，Tri-X 标志特征）
 *   3. 深黑（shadows=-20, blacks=-28，Tri-X 深黑特征）
 *   4. 粗颗粒（grain=0.26, grainSize=1.4，暗部增强 2x）
 *   5. 银盐光晕（bloom=0.04，高光区域银粒扩散，冷白色）
 *   6. 显影柔化（developmentSoftness=0.025，D-76 显影液扩散）
 *   7. 明显暗角（vignette=0.18，35mm 相机特征）
 *   8. 无色差（chromaticAberration=0.0，黑白胶片无色差）
 *   9. 无肤色保护（黑白模式，skinHueProtect=0.0）
 *
 * GPU Pipeline 顺序（12 pass，镜像 iOS BWClassicShader.metal）：
 *   Camera Frame
 *   → Pass 0: 黑白混合（Channel Mixer，Tri-X 感光特性权重）
 *   → Pass 1: Tone Curve（深黑+高光干净+中间调微对比）
 *   → Pass 2: 对比度（contrast=1.28）
 *   → Pass 3: Clarity 微对比（clarity=14）
 *   → Pass 4: Highlight Rolloff（胶片高光保护，0.18）
 *   → Pass 5: 银盐光晕（bloom=0.04，冷白银盐扩散）
 *   → Pass 6: 传感器非均匀性（中心增亮+边缘衰减）
 *   → Pass 7: 显影柔化（developmentSoftness=0.025）
 *   → Pass 8: 化学不规则感（chemicalIrregularity=0.018）
 *   → Pass 9: 亮度噪声（luminanceNoise=0.04）
 *   → Pass 10: 粗颗粒（grain=0.26, grainSize=1.4，暗部增强）
 *   → Pass 11: 暗角（vignette=0.18）
 *   → Output
 * ═══════════════════════════════════════════════════════════════════════════
 */
object BWClassicGLRenderer {

    /**
     * BW Classic Fragment Shader（OpenGL ES 3.0）
     *
     * Kodak Tri-X 400 Tone Curve 控制点（归一化）：
     *   Input:  0      0.063  0.125  0.251  0.502  0.627  0.878  1.0
     *   Output: 0.000  0.020  0.060  0.175  0.490  0.640  0.920  1.0
     * 特点：深黑（阴影强压）+ 中间调微对比 + 高光干净不溢
     *
     * Channel Mixer 权重（Tri-X 400 真实感光特性）：
     *   R=0.22（红色不敏感，肤色偏暗）
     *   G=0.72（绿色主要亮度来源）
     *   B=0.06（蓝色偏低，天空深暗，云彩对比强）
     */
    const val FRAGMENT_SHADER = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in  vec2 vTexCoord;
out vec4 fragColor;
uniform samplerExternalOES uCameraTexture;

// ── 通用参数 ────────────────────────────────────────────────────────────────
uniform float uContrast;
uniform float uSaturation;
uniform float uTemperatureShift;
uniform float uTintShift;
uniform float uGrainAmount;
uniform float uVignetteAmount;
uniform float uChromaticAberration;
uniform float uBloomAmount;
uniform float uHalationAmount;
uniform float uTime;

// ── BW Classic 专用 Uniform ─────────────────────────────────────────────────
uniform float uGrainSize;            // 颗粒大小（BW Classic=1.4，粗颗粒）
uniform float uSharpness;            // 锐度倍数（BW Classic=1.30）
uniform float uHighlightRolloff;     // 高光柔和滴落（BW Classic=0.18）
uniform float uEdgeFalloff;          // 边缘曝光衰减（BW Classic=0.035）
uniform float uExposureVariation;    // 曝光波动（BW Classic=0.015）
uniform float uCornerWarmShift;      // 角落偏移（BW Classic=0.0，黑白无色偏）
uniform float uCenterGain;           // 中心增亮（BW Classic=0.008）
uniform float uDevelopmentSoftness;  // 显影柔化（BW Classic=0.025，D-76 扩散）
uniform float uChemicalIrregularity; // 化学不规则感（BW Classic=0.018）
uniform float uLuminanceNoise;       // 亮度噪声（BW Classic=0.04）
uniform float uChromaNoise;          // 彩色噪声（BW Classic=0.0，黑白无彩色噪声）

// ── 肤色保护（黑白模式关闭）────────────────────────────────────────────────
uniform float uSkinHueProtect;       // 黑白模式=0.0，关闭
uniform float uSkinSatProtect;
uniform float uSkinLumaSoften;
uniform float uSkinRedLimit;

// ── BW Classic 专有：Channel Mixer ─────────────────────────────────────────
uniform float uBwChannelR;           // 红色权重（Tri-X=0.22）
uniform float uBwChannelG;           // 绿色权重（Tri-X=0.72）
uniform float uBwChannelB;           // 蓝色权重（Tri-X=0.06）
uniform float uClarity;              // Clarity 微对比（BW Classic=14.0）
uniform float uToneCurveStrength;    // Tone Curve 强度（BW Classic=1.0）

// ── 工具函数 ─────────────────────────────────────────────────────────────────

float bwRandom(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

/// Kodak Tri-X 400 Tone Curve（深黑+高光干净+中间调微对比）
float bwToneCurve(float x) {
    float inp[8];
    inp[0]=0.0; inp[1]=0.063; inp[2]=0.125; inp[3]=0.251;
    inp[4]=0.502; inp[5]=0.627; inp[6]=0.878; inp[7]=1.0;
    float outp[8];
    outp[0]=0.000; outp[1]=0.020; outp[2]=0.060; outp[3]=0.175;
    outp[4]=0.490; outp[5]=0.640; outp[6]=0.920; outp[7]=1.0;
    for (int i = 0; i < 7; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outp[i], outp[i + 1], t);
        }
    }
    return outp[7];
}

/// Clarity 微对比（局部对比度增强，模拟 Tri-X 质感）
float bwClarity(float luma, float clarity) {
    if (clarity <= 0.0) return luma;
    float mid = 0.5;
    float delta = luma - mid;
    float boost = delta * clarity * 0.015;
    return clamp(luma + boost, 0.0, 1.0);
}

/// Highlight Rolloff（胶片高光保护，0.18）
float bwHighlightRolloff(float luma, float rolloff) {
    if (rolloff <= 0.0) return luma;
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.45;
    return clamp(luma * compress, 0.0, 1.0);
}

/// 银盐光晕（bloom=0.04，高光区域银粒扩散）
float bwSilverBloom(float luma, float bloom) {
    if (bloom <= 0.0) return luma;
    float h = clamp((luma - 0.78) / 0.22, 0.0, 1.0);
    return clamp(luma + h * bloom * 0.6, 0.0, 1.0);
}

/// 传感器非均匀性（35mm 相机）
float bwCenterEdge(vec2 uv, float centerGain, float edgeFalloff) {
    vec2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

float bwVignette(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── 主函数 ───────────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;
    vec2 texelSize = vec2(1.0 / 1080.0, 1.0 / 1440.0);

    // 采样原始彩色图像
    vec3 colorIn = texture(uCameraTexture, uv).rgb;

    // === Pass 0: 黑白混合（Channel Mixer，Tri-X 感光特性权重）===
    float bwR = uBwChannelR > 0.0 ? uBwChannelR : 0.22;
    float bwG = uBwChannelG > 0.0 ? uBwChannelG : 0.72;
    float bwB = uBwChannelB > 0.0 ? uBwChannelB : 0.06;
    float bwSum = bwR + bwG + bwB;
    if (bwSum > 0.001) { bwR /= bwSum; bwG /= bwSum; bwB /= bwSum; }
    float luma = dot(colorIn, vec3(bwR, bwG, bwB));

    // === Pass 1: Tone Curve（深黑+高光干净+中间调微对比）===
    luma = bwToneCurve(luma);

    // === Pass 2: 对比度（contrast=1.28）===
    luma = clamp((luma - 0.5) * uContrast + 0.5, 0.0, 1.0);

    // === Pass 3: Clarity 微对比（clarity=14）===
    luma = bwClarity(luma, uClarity);

    // === Pass 4: Highlight Rolloff（胶片高光保护，0.18）===
    luma = bwHighlightRolloff(luma, uHighlightRolloff);

    // === Pass 5: 银盐光晕（bloom=0.04，冷白银盐扩散）===
    luma = bwSilverBloom(luma, uBloomAmount);

    // === Pass 6: 传感器非均匀性（中心增亮+边缘衰减）===
    if (uCenterGain > 0.0 || uEdgeFalloff > 0.0) {
        float factor = bwCenterEdge(uv, uCenterGain, uEdgeFalloff);
        luma = clamp(luma * factor, 0.0, 1.0);
    }
    if (uExposureVariation > 0.0) {
        float evn = bwRandom(uv * 0.1, uTime * 0.01) - 0.5;
        luma = clamp(luma + evn * uExposureVariation * 0.3, 0.0, 1.0);
    }

    // === Pass 7: 显影柔化（developmentSoftness=0.025，D-76 显影液扩散）===
    if (uDevelopmentSoftness > 0.0) {
        float s1 = dot(texture(uCameraTexture, uv + vec2(texelSize.x, 0.0)).rgb, vec3(bwR, bwG, bwB));
        float s2 = dot(texture(uCameraTexture, uv - vec2(texelSize.x, 0.0)).rgb, vec3(bwR, bwG, bwB));
        float s3 = dot(texture(uCameraTexture, uv + vec2(0.0, texelSize.y)).rgb, vec3(bwR, bwG, bwB));
        float s4 = dot(texture(uCameraTexture, uv - vec2(0.0, texelSize.y)).rgb, vec3(bwR, bwG, bwB));
        float blurred = (s1 + s2 + s3 + s4) * 0.25;
        // 对 blurred 也应用 tone curve
        blurred = bwToneCurve(blurred);
        luma = mix(luma, blurred, uDevelopmentSoftness);
    }

    // === Pass 8: 化学不规则感（chemicalIrregularity=0.018）===
    if (uChemicalIrregularity > 0.0) {
        vec2 blockUV = floor(uv * 24.0) / 24.0;
        float irr = (bwRandom(blockUV, 0.55) - 0.5) * uChemicalIrregularity;
        luma = clamp(luma + irr * 0.6, 0.0, 1.0);
    }

    // === Pass 9: 亮度噪声（luminanceNoise=0.04）===
    if (uLuminanceNoise > 0.0) {
        vec2 lnUV = uv / max(uGrainSize * 0.003, 0.001);
        float ln = (bwRandom(lnUV, floor(uTime * 30.0) / 30.0 + 0.5) - 0.5);
        float darkBoost = 1.0 + (1.0 - luma) * 0.8;
        luma = clamp(luma + ln * uLuminanceNoise * 0.2 * darkBoost, 0.0, 1.0);
    }

    // === Pass 10: 粗颗粒（grain=0.26, grainSize=1.4，暗部增强 2x）===
    if (uGrainAmount > 0.0) {
        vec2 grainUV = uv / max(uGrainSize * 0.003, 0.001);
        float grain = bwRandom(grainUV, floor(uTime * 30.0) / 30.0) - 0.5;
        // Tri-X 颗粒在暗部更明显（暗部颗粒是亮部的 2 倍）
        float darkBoost = 1.0 + (1.0 - luma) * 1.0;
        luma = clamp(luma + grain * uGrainAmount * 0.28 * darkBoost, 0.0, 1.0);
    }

    // === Pass 11: 暗角（vignette=0.18，35mm 相机明显暗角）===
    if (uVignetteAmount > 0.0) {
        luma *= bwVignette(uv, uVignetteAmount);
    }

    fragColor = vec4(vec3(clamp(luma, 0.0, 1.0)), 1.0);
}
"""
}
