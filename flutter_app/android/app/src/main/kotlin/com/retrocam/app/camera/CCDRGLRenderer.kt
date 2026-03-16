package com.retrocam.app.camera

/**
 * CCDRGLRenderer — CCD R (2003-2006 早期 CCD 数码相机，冷蓝绿调) GLSL Shader
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 风格定位：
 *   Sony Cyber-shot DSC-T 系列 / Canon IXUS 早期型号（2003-2006）
 *   核心气质：冷蓝绿 + CCD 彩色噪声 + 高光 bloom 溢出 + 早期数码味
 *
 * 核心特征（基于 2003-2006 早期 CCD 传感器真实特性）：
 *   1. 冷蓝绿色调（temperature=-15，早期 CCD 白平衡算法偏冷）
 *   2. R 通道压暗（colorBiasR=-0.030，偏冷非暖）
 *   3. B 通道增强（colorBiasB=+0.048，天空极蓝）
 *   4. G 通道偏青（colorBiasG=+0.018，早期 CCD 青绿偏向）
 *   5. 强彩色噪声（chromaNoise=0.08，早期 CCD 传感器标志特征）
 *   6. 强 bloom（bloom=0.12，CCD 高光溢出特征，冷白色）
 *   7. 低 highlightRolloff（0.06，CCD 高光保护差，允许略溢）
 *   8. 阴影提亮（shadows=+6，CCD 宽容度低，厂商补偿）
 *   9. 廉价镜头色差（chromaticAberration=0.11）
 *  10. 肤色保护（skinRedLimit=1.02，防止冷 LUT 削红让肤色发青）
 *
 * GPU Pipeline 顺序（14 pass，镜像 iOS CCDRShader.metal）：
 *   Camera Frame
 *   → Pass 0: 色差（早期廉价镜头，0.11）
 *   → Pass 1: 白平衡（冷蓝绿，temperature=-15）
 *   → Pass 2: Highlight Rolloff（低保护，允许高光略溢，0.06）
 *   → Pass 3: 早期 CCD Tone Curve（阴影提亮+高光快速溢出）
 *   → Pass 4: RGB 通道倾向（R-0.030, G+0.018, B+0.048）
 *   → Pass 5: 对比度 + 饱和度
 *   → Pass 6: CCD Bloom + Halation（冷白/蓝紫）
 *   → Pass 7: 肤色保护（防止冷 LUT 让肤色发青）
 *   → Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减 + 冷角）
 *   → Pass 9: 传感器热噪声（chemicalIrregularity=0.008）
 *   → Pass 10: 亮度噪声（luminanceNoise=0.08）
 *   → Pass 11: 彩色噪声（chromaNoise=0.08，早期 CCD 标志）
 *   → Pass 12: 颗粒（grain=0.22, grainSize=1.3）
 *   → Pass 13: 暗角（vignette=0.12）
 *   → Output
 * ═══════════════════════════════════════════════════════════════════════════
 */
object CCDRGLRenderer {

    /**
     * CCD R Fragment Shader（OpenGL ES 3.0）
     *
     * 早期 CCD Tone Curve 控制点（归一化）：
     *   Input:  0      0.063  0.251  0.502  0.627  0.878  1.0
     *   Output: 0.020  0.085  0.270  0.510  0.660  0.940  1.0
     * 特点：黑位轻提（CCD 黑位不纯）+ 阴影明显提亮（宽容度低补偿）
     *       + 中间调平 + 高光快速溢出（CCD 高光保护差）
     *
     * 彩色噪声颜色权重：B(0.16) > G(0.14) > R(0.10)
     * 与 CCD R 冷蓝绿色调一致，蓝色噪声最强。
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

// ── CCD R 专用 Uniform ──────────────────────────────────────────────────────
uniform float uColorBiasR;           // R 通道偏移（CCD R=-0.030）
uniform float uColorBiasG;           // G 通道偏移（CCD R=+0.018）
uniform float uColorBiasB;           // B 通道偏移（CCD R=+0.048）
uniform float uGrainSize;            // 颗粒大小（CCD R=1.3）
uniform float uSharpness;            // 锐度倍数（CCD R=1.06）
uniform float uHighlightRolloff;     // 高光柔和滴落（CCD R=0.06，低保护）
uniform float uEdgeFalloff;          // 边缘曝光衰减（CCD R=0.04）
uniform float uExposureVariation;    // 曝光波动（CCD R=0.025）
uniform float uCornerWarmShift;      // 角落偏移（CCD R=-0.010，负值=偏冷蓝）
uniform float uCenterGain;           // 中心增亮（CCD R=0.020）
uniform float uDevelopmentSoftness;  // 化学显影柔化（CCD R=0.000，数码相机）
uniform float uChemicalIrregularity; // 传感器热噪声（CCD R=0.008）
uniform float uLuminanceNoise;       // 亮度噪声（CCD R=0.08）
uniform float uChromaNoise;          // 彩色噪声（CCD R=0.08，早期 CCD 标志）

// ── 肤色保护 Uniform ────────────────────────────────────────────────────────
uniform float uSkinHueProtect;       // 肤色保护（CCD R=1.0）
uniform float uSkinSatProtect;       // 肤色饱和度保护（CCD R=0.94）
uniform float uSkinLumaSoften;       // 肤色亮度柔化（CCD R=0.03）
uniform float uSkinRedLimit;         // 肤色红限（CCD R=1.02，严格限红）

// ── 工具函数 ─────────────────────────────────────────────────────────────────

float ccdrRandom(vec2 uv, float seed) {
    return fract(sin(dot(uv + seed, vec2(127.1, 311.7))) * 43758.5453123);
}

vec3 ccdrWhiteBalance(vec3 c, float tempShift, float tintShift) {
    float t = tempShift / 1000.0;
    float g = tintShift / 1000.0;
    c.r = clamp(c.r + t * 0.3, 0.0, 1.0);
    c.b = clamp(c.b - t * 0.3, 0.0, 1.0);
    c.g = clamp(c.g + g * 0.2, 0.0, 1.0);
    return c;
}

/// 早期 CCD Tone Curve（阴影提亮+高光快速溢出）
float ccdrToneCurve(float x) {
    float inp[7];
    inp[0]=0.0; inp[1]=0.063; inp[2]=0.251; inp[3]=0.502;
    inp[4]=0.627; inp[5]=0.878; inp[6]=1.0;
    float outp[7];
    outp[0]=0.020; outp[1]=0.085; outp[2]=0.270; outp[3]=0.510;
    outp[4]=0.660; outp[5]=0.940; outp[6]=1.0;
    for (int i = 0; i < 6; i++) {
        if (x <= inp[i + 1]) {
            float t = (x - inp[i]) / (inp[i + 1] - inp[i]);
            return mix(outp[i], outp[i + 1], t);
        }
    }
    return outp[6];
}

vec3 ccdrContrast(vec3 c, float contrast) {
    return clamp((c - 0.5) * contrast + 0.5, 0.0, 1.0);
}

vec3 ccdrSaturation(vec3 c, float sat) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(lum), c, sat), 0.0, 1.0);
}

/// Highlight Rolloff（低保护，允许 CCD 高光略溢）
vec3 ccdrHighlightRolloff(vec3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    float compress = 1.0 - highlight * highlight * 0.25;
    return clamp(color * compress, 0.0, 1.0);
}

/// CCD Bloom（冷白）+ Halation（蓝紫）
vec3 ccdrBloomHalation(vec3 color, float bloom, float halation) {
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    vec3 result = color;
    if (bloom > 0.0) {
        float h = clamp((luma - 0.70) / 0.30, 0.0, 1.0);
        vec3 bloomColor = vec3(0.85, 0.92, 1.0); // 冷白
        result = clamp(result + bloomColor * h * bloom * 0.5, 0.0, 1.0);
    }
    if (halation > 0.0) {
        float h = clamp((luma - 0.80) / 0.20, 0.0, 1.0);
        vec3 halationColor = vec3(0.7, 0.8, 1.0); // 蓝紫
        result = clamp(result + halationColor * h * halation * 0.3, 0.0, 1.0);
    }
    return result;
}

/// 肤色保护（防止冷 LUT 让肤色发青）
vec3 ccdrSkinProtect(vec3 color, float protect,
                     float satProt, float lumaSoften, float redLimit) {
    if (protect < 0.5) return color;
    float maxC = max(max(color.r, color.g), color.b);
    float minC = min(min(color.r, color.g), color.b);
    float delta = maxC - minC;
    float h = 0.0;
    if (delta > 0.001) {
        if (maxC == color.r)      h = mod((color.g - color.b) / delta, 6.0);
        else if (maxC == color.g) h = (color.b - color.r) / delta + 2.0;
        else                      h = (color.r - color.g) / delta + 4.0;
        h = h / 6.0;
        if (h < 0.0) h += 1.0;
    }
    float skinMask = smoothstep(0.030, 0.065, h) * (1.0 - smoothstep(0.100, 0.140, h));
    if (skinMask < 0.001) return color;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    vec3 prot = mix(vec3(luma), color, satProt);
    prot = clamp(prot + lumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, redLimit);
    return mix(color, prot, skinMask);
}

/// 传感器非均匀性
float ccdrCenterEdge(vec2 uv, float centerGain, float edgeFalloff) {
    vec2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

/// 角落偏冷（负值 shift = 偏冷蓝）
vec3 ccdrCornerShift(vec2 uv, vec3 color, float shift) {
    vec2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor;
    color.r = clamp(color.r + s * 0.5, 0.0, 1.0);
    color.g = clamp(color.g + s * 0.2, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.3, 0.0, 1.0);
    return color;
}

float ccdrVignette(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return clamp(1.0 - dot(d, d) * amount * 2.5, 0.0, 1.0);
}

// ── 主函数 ───────────────────────────────────────────────────────────────────
void main() {
    vec2 uv = vTexCoord;
    vec2 texelSize = vec2(1.0 / 1080.0, 1.0 / 1440.0);

    // === Pass 0: 色差（早期廉价镜头，0.11）===
    vec3 color;
    if (uChromaticAberration > 0.0) {
        float ca = uChromaticAberration * texelSize.x * 20.0;
        float r = texture(uCameraTexture, uv + vec2(ca, 0.0)).r;
        float g = texture(uCameraTexture, uv).g;
        float b = texture(uCameraTexture, uv - vec2(ca, 0.0)).b;
        color = vec3(r, g, b);
    } else {
        color = texture(uCameraTexture, uv).rgb;
    }

    // === Pass 1: 白平衡（冷蓝绿，temperature=-15）===
    color = ccdrWhiteBalance(color, uTemperatureShift, uTintShift);

    // === Pass 2: Highlight Rolloff（低保护，0.06）===
    color = ccdrHighlightRolloff(color, uHighlightRolloff);

    // === Pass 3: 早期 CCD Tone Curve ===
    color.r = ccdrToneCurve(color.r);
    color.g = ccdrToneCurve(color.g);
    color.b = ccdrToneCurve(color.b);

    // === Pass 4: RGB 通道倾向（R-0.030, G+0.018, B+0.048）===
    color.r = clamp(color.r + uColorBiasR, 0.0, 1.0);
    color.g = clamp(color.g + uColorBiasG, 0.0, 1.0);
    color.b = clamp(color.b + uColorBiasB, 0.0, 1.0);

    // === Pass 5: 对比度 + 饱和度 ===
    color = ccdrContrast(color, uContrast);
    color = ccdrSaturation(color, uSaturation);

    // === Pass 6: CCD Bloom + Halation（冷白/蓝紫）===
    color = ccdrBloomHalation(color, uBloomAmount, uHalationAmount);

    // === Pass 7: 肤色保护 ===
    color = ccdrSkinProtect(color,
        uSkinHueProtect, uSkinSatProtect,
        uSkinLumaSoften, uSkinRedLimit);

    // === Pass 8: 传感器非均匀性（中心增亮 + 边缘衰减 + 冷角）===
    if (uCenterGain > 0.0 || uEdgeFalloff > 0.0) {
        float factor = ccdrCenterEdge(uv, uCenterGain, uEdgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    if (uExposureVariation > 0.0) {
        float evn = ccdrRandom(uv * 0.1, uTime * 0.01) - 0.5;
        color = clamp(color + evn * uExposureVariation * 0.3, 0.0, 1.0);
    }
    color = ccdrCornerShift(uv, color, uCornerWarmShift);

    // === Pass 9: 传感器热噪声（chemicalIrregularity=0.008）===
    if (uChemicalIrregularity > 0.0) {
        vec2 blockUV = floor(uv * 32.0) / 32.0;
        float irr = (ccdrRandom(blockUV, 0.77) - 0.5) * uChemicalIrregularity;
        color = clamp(color + irr * 0.5, 0.0, 1.0);
    }

    // === Pass 10: 亮度噪声（luminanceNoise=0.08）===
    if (uLuminanceNoise > 0.0) {
        vec2 lnUV = uv / max(uGrainSize * 0.003, 0.001);
        float ln = (ccdrRandom(lnUV, floor(uTime * 30.0) / 30.0) - 0.5);
        float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float darkBoost = 1.0 + (1.0 - luma) * 1.2;
        color = clamp(color + ln * uLuminanceNoise * 0.2 * darkBoost, 0.0, 1.0);
    }

    // === Pass 11: 彩色噪声（chromaNoise=0.08，B>G>R，与冷蓝绿色调一致）===
    if (uChromaNoise > 0.0) {
        vec2 cnUV = uv / max(uGrainSize * 0.004, 0.001);
        float cr = (ccdrRandom(cnUV, 1.1) - 0.5) * uChromaNoise * 0.10;
        float cg = (ccdrRandom(cnUV, 2.3) - 0.5) * uChromaNoise * 0.14;
        float cb = (ccdrRandom(cnUV, 3.7) - 0.5) * uChromaNoise * 0.16; // B 最强
        color = clamp(color + vec3(cr, cg, cb), 0.0, 1.0);
    }

    // === Pass 12: 颗粒（grain=0.22, grainSize=1.3）===
    if (uGrainAmount > 0.0) {
        vec2 grainUV = uv / max(uGrainSize * 0.003, 0.001);
        float grain = ccdrRandom(grainUV, floor(uTime * 30.0) / 30.0) - 0.5;
        float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float darkBoost = 1.0 + (1.0 - luma) * 0.6;
        color = clamp(color + grain * uGrainAmount * 0.22 * darkBoost, 0.0, 1.0);
    }

    // === Pass 13: 暗角（vignette=0.12）===
    if (uVignetteAmount > 0.0) {
        color *= ccdrVignette(uv, uVignetteAmount);
    }

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
"""
}
