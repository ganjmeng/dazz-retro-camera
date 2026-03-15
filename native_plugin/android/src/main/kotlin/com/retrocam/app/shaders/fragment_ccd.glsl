#extension GL_OES_EGL_image_external : require
precision mediump float;

// 相机输入纹理（来自 CameraX 的 SurfaceTexture）
uniform samplerExternalOES uCameraTexture;
// LUT 纹理（用于色彩重映射）
uniform sampler2D uLutTexture;
// 胶片颗粒纹理
uniform sampler2D uGrainTexture;

// ── 基础色彩参数 ──────────────────────────────────────────────
uniform float uContrast;           // 对比度乘数，1.0 = 原始
uniform float uSaturation;         // 饱和度乘数，1.0 = 原始；0.0 = 黑白
uniform float uTemperatureShift;   // 色温偏移（负数偏冷/蓝，正数偏暖/橙）
uniform float uTintShift;          // 绿/洋红偏色（负数偏绿，正数偏洋红）

// ── Lightroom 风格曲线参数（-100 ~ +100）─────────────────────
uniform float uHighlights;         // 高光压缩/提亮
uniform float uShadows;            // 阴影压缩/提亮
uniform float uWhites;             // 白场偏移
uniform float uBlacks;             // 黑场偏移
uniform float uClarity;            // 中间调微对比度（Clarity）
uniform float uVibrance;           // 智能饱和度（低饱和区域优先）

// ── RGB 通道独立偏移（-1.0 ~ +1.0）──────────────────────────
uniform float uColorBiasR;
uniform float uColorBiasG;
uniform float uColorBiasB;

// ── 胶片效果参数 ──────────────────────────────────────────────
uniform float uGrainAmount;        // 颗粒强度 0~1
uniform float uNoiseAmount;        // 数字噪点强度 0~1
uniform float uVignetteAmount;     // 暗角强度 0~1
uniform float uChromaticAberration;// 色差强度
uniform float uBloomAmount;        // 高光光晕强度
uniform float uTime;               // 动态噪点时间种子
uniform float uDistortion;         // 镜头畸变：负值=桶形(鱼眼), 正值=枕形, 0=无畸变

varying vec2 vTexCoord;

// ============================================================
// 工具函数
// ============================================================

// 计算暗角强度
float vignetteEffect(vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    return 1.0 - dot(d, d) * amount * 2.5;
}

// 简单的伪随机噪点生成
float random(vec2 st, float seed) {
    return fract(sin(dot(st + seed, vec2(12.9898, 78.233))) * 43758.5453);
}

// 色温偏移：负值偏冷（蓝），正值偏暖（橙）
vec3 applyTemperatureShift(vec3 color, float shift) {
    float s = shift / 1000.0;
    color.r = clamp(color.r - s * 0.3, 0.0, 1.0);
    color.b = clamp(color.b + s * 0.3, 0.0, 1.0);
    return color;
}

// Tint 偏色：负值偏绿，正值偏洋红
vec3 applyTint(vec3 color, float tint) {
    float t = tint / 100.0;
    color.g = clamp(color.g - t * 0.12, 0.0, 1.0);
    color.r = clamp(color.r + t * 0.06, 0.0, 1.0);
    color.b = clamp(color.b + t * 0.06, 0.0, 1.0);
    return color;
}

// 对比度调整（围绕 0.5 缩放）
vec3 applyContrast(vec3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

// 饱和度调整（BT.709 亮度权重）
vec3 applySaturation(vec3 color, float saturation) {
    float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    return mix(vec3(lum), color, saturation);
}

// 黑场/白场偏移
vec3 applyBlacksWhites(vec3 color, float blacks, float whites) {
    float blacksOffset = blacks / 100.0 * (20.0 / 255.0);
    float whitesScale  = 1.0 + whites / 100.0 * 0.15;
    return clamp(color * whitesScale + blacksOffset, 0.0, 1.0);
}

// 高光/阴影压缩（非线性曲线模拟）
vec3 applyHighlightsShadows(vec3 color, float highlights, float shadows) {
    float hScale  = 1.0 + highlights / 100.0 * 0.12;
    float hOffset = -highlights / 100.0 * 0.12 * (191.0 / 255.0);
    float sScale  = 1.0 - shadows / 100.0 * 0.08;
    float sOffset = shadows / 100.0 * 0.08 * (64.0 / 255.0) + shadows / 100.0 * (12.0 / 255.0);
    float scale   = hScale * sScale;
    float offset  = hOffset * sScale + sOffset;
    return clamp(color * scale + offset, 0.0, 1.0);
}

// Clarity：中间调微对比度
vec3 applyClarity(vec3 color, float clarity) {
    float c      = clarity / 100.0;
    float boost  = 1.0 + c * 0.15;
    float offset = -c * 0.15 * 0.5;
    return clamp(color * boost + offset, 0.0, 1.0);
}

// Vibrance：智能饱和度（低饱和区域优先提升）
vec3 applyVibrance(vec3 color, float vibrance) {
    float v   = vibrance / 100.0 * 0.6;
    float sat = 1.0 + v;
    const float lr = 0.2126;
    const float lg = 0.7152;
    const float lb = 0.0722;
    float sr = (1.0 - sat) * lr;
    float sg = (1.0 - sat) * lg;
    float sb = (1.0 - sat) * lb;
    return clamp(vec3(
        color.r * (sr + sat) + color.g * sg + color.b * sb,
        color.r * sr + color.g * (sg + sat) + color.b * sb,
        color.r * sr + color.g * sg + color.b * (sb + sat)
    ), 0.0, 1.0);
}

// RGB 通道偏移
vec3 applyColorBias(vec3 color, float r, float g, float b) {
    return clamp(color + vec3(r * (30.0/255.0), g * (30.0/255.0), b * (30.0/255.0)), 0.0, 1.0);
}

// ============================================================
// 镜头畸变：Brown-Conrady 径向畸变模型
// k1 < 0 → 桶形畸变（鱼眼/广角），k1 > 0 → 枕形畸变（长焦）
// 公式：r' = r * (1 + k1 * r²)，在 UV 采样前变换坐标
// ============================================================
vec2 applyLensDistortion(vec2 uv, float k1) {
    if (abs(k1) < 0.001) return uv;
    vec2 centered = uv - 0.5;           // 以图像中心为原点
    float r2 = dot(centered, centered); // r²
    float scale = 1.0 + k1 * r2;       // 畸变缩放因子
    scale = max(scale, 0.1);            // 防止极端值导致 UV 翻转
    return centered / scale + 0.5;      // 反变换：采样点往内收 = 图像向外鼓
}

// ============================================================
// 主函数
// ============================================================

void main() {
    vec2 uv = vTexCoord;

    // === Pass 0: 镜头畸变（在所有色彩处理之前变换 UV）===
    // uDistortion 直接映射到 k1（Brown-Conrady 系数）
    // 鱼眼 distortion=-0.60 → k1=-0.45（强桶形）
    // 广角 distortion=-0.08 → k1=-0.06（轻微桶形）
    // 长焦 distortion=+0.05 → k1=+0.0375（轻微枕形）
    float k1 = uDistortion * 0.75;
    uv = applyLensDistortion(uv, k1);
    // 边缘裁切：畸变后 UV 超出 [0,1] 的区域填充黑色
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // === Pass 1: 色差 (Chromatic Aberration) ===
    float ca = uChromaticAberration;
    float r = texture2D(uCameraTexture, uv + vec2(ca, 0.0)).r;
    float g = texture2D(uCameraTexture, uv).g;
    float b = texture2D(uCameraTexture, uv - vec2(ca, 0.0)).b;
    vec3 color = vec3(r, g, b);

    // === Pass 2: 色温 + Tint ===
    color = applyTemperatureShift(color, uTemperatureShift);
    color = applyTint(color, uTintShift);

    // === Pass 3: 黑场/白场 ===
    color = applyBlacksWhites(color, uBlacks, uWhites);

    // === Pass 4: 高光/阴影压缩 ===
    color = applyHighlightsShadows(color, uHighlights, uShadows);

    // === Pass 5: 对比度 ===
    color = applyContrast(color, uContrast);

    // === Pass 6: Clarity（中间调微对比度）===
    if (abs(uClarity) > 0.5) {
        color = applyClarity(color, uClarity);
    }

    // === Pass 7: 饱和度 + Vibrance ===
    color = applySaturation(color, uSaturation);
    if (abs(uVibrance) > 0.5) {
        color = applyVibrance(color, uVibrance);
    }

    // === Pass 8: RGB 通道偏移 ===
    if (abs(uColorBiasR) + abs(uColorBiasG) + abs(uColorBiasB) > 0.001) {
        color = applyColorBias(color, uColorBiasR, uColorBiasG, uColorBiasB);
    }

    // === Pass 9: 高光溢出 (Bloom) ===
    float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
    if (luminance > 0.8 && uBloomAmount > 0.0) {
        float bloom = (luminance - 0.8) * uBloomAmount * 2.0;
        color = clamp(color + vec3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }

    // === Pass 10: 胶片颗粒 (Grain) ===
    if (uGrainAmount > 0.0) {
        vec3 grain = texture2D(uGrainTexture, uv * 2.0).rgb;
        color = clamp(color + (grain - 0.5) * uGrainAmount * 0.3, 0.0, 1.0);
    }

    // === Pass 11: 动态数字噪点 (Noise) ===
    if (uNoiseAmount > 0.0) {
        float noise = random(uv, uTime) - 0.5;
        float darkMask = 1.0 - luminance;
        color = clamp(color + noise * uNoiseAmount * 0.2 * darkMask, 0.0, 1.0);
    }

    // === Pass 12: 暗角 (Vignette) ===
    float vignette = vignetteEffect(uv, uVignetteAmount);
    color *= vignette;

    gl_FragColor = vec4(color, 1.0);
}
