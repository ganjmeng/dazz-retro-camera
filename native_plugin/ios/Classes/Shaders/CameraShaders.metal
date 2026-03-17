#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点着色器

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// MARK: - CCD 效果 Uniform 参数

struct CCDParams {
    // ── 基础色彩 ──────────────────────────────────────────────
    float contrast;            // 对比度乘数，1.0 = 原始
    float saturation;          // 饱和度乘数，1.0 = 原始；0.0 = 黑白
    float temperatureShift;    // 色温偏移（负数偏冷/蓝，正数偏暖/橙）
    float tintShift;           // 绿/洋红偏色（负数偏绿，正数偏洋红）
    float exposureOffset;      // 曝光偏移（EV，-2.0~+2.0，正数提亮）

    // ── Lightroom 风格曲线（-100 ~ +100）─────────────────────
    float highlights;          // 高光压缩/提亮
    float shadows;             // 阴影压缩/提亮
    float whites;              // 白场偏移
    float blacks;              // 黑场偏移
    float clarity;             // 中间调微对比度（Clarity）
    float vibrance;            // 智能饱和度

    // ── RGB 通道独立偏移（-1.0 ~ +1.0）──────────────────────
    float colorBiasR;
    float colorBiasG;
    float colorBiasB;

    // ── 胶片效果 ──────────────────────────────────────────────
    float grainAmount;         // 颗粒强度 0~1
    float noiseAmount;         // 数字噪点强度 0~1
    float vignetteAmount;      // 暗角强度 0~1（preset 层）
    float chromaticAberration; // 色差强度
    float bloomAmount;         // 高光光晕强度
    float halationAmount;      // 光晕（胶片漏光感）
    float sharen;              // 锐化（注：保持原字段名）
    float blurRadius;          // 模糊半径
    float jpegArtifacts;       // JPEG 压缩感
    float time;                // 动态噪点时间种子
    float distortion;          // 镜头畸变：负值=桶形(鱼眼), 正值=枕形, 0=无畸变
    float zoomFactor;          // 镜头缩放倍数：1.0=标准, 0.5=超广角/鱼眼（UV 缩放）
    float lensVignette;        // 镜头层暗角（叠加在 preset 暗角之上）
};

// MARK: - 工具函数

/// 镜头畸变：Brown-Conrady 径向畸变模型
/// k1 < 0 → 桶形畸变（鱼眼/广角），k1 > 0 → 枕形畸变（长焦）
float2 applyLensDistortion(float2 uv, float k1) {
    if (abs(k1) < 0.001) return uv;
    float2 centered = uv - 0.5;           // 以图像中心为原点
    float r2 = dot(centered, centered);   // r²
    float scale = 1.0 + k1 * r2;         // 畸变缩放因子
    scale = max(scale, 0.1);              // 防止极端值导致 UV 翻转
    return centered / scale + 0.5;        // 反变换：采样点往内收 = 图像向外鼓
}

/// 镜头缩放：zoomFactor < 1.0 时视野扩大（鱼眼效果），超出 [0,1] 的区域填黑
/// zoomFactor = 0.5 时，UV 范围扩展到 [-0.25, 1.25]，超出部分为黑色圆形遮罩
float2 applyZoom(float2 uv, float zoomFactor) {
    if (abs(zoomFactor - 1.0) < 0.001) return uv;
    float2 centered = (uv - 0.5) * zoomFactor;
    return centered + 0.5;
}

/// 暗角强度（椭圆径向渐变）
float vignetteEffect(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return 1.0 - dot(d, d) * amount * 2.5;
}

/// 伪随机噪点
float random(float2 st, float seed) {
    return fract(sin(dot(st + seed, float2(12.9898, 78.233))) * 43758.5453);
}

/// 色温偏移：负值偏冷（蓝），正值偏暖（橙）
/// 项目定义：1800K=最暖(橙)，8000K=最冷(蓝)；offset = (K-4800)/32，1800K→负值，8000K→正值
/// 因此 shift>0 = 冷（减R加B），shift<0 = 暖（加R减B）
float3 applyTemperatureShift(float3 color, float shift) {
    float s = shift / 1000.0;
    color.r = clamp(color.r - s * 0.3, 0.0, 1.0);
    color.b = clamp(color.b + s * 0.3, 0.0, 1.0);
    return color;
}

/// 曝光偏移：EV 单位，正数提亮，负数压暗
float3 applyExposure(float3 color, float ev) {
    float gain = pow(2.0, ev);
    return clamp(color * gain, 0.0, 1.0);
}

/// Tint 偏色：负值偏绿，正值偏洋红
float3 applyTint(float3 color, float tint) {
    float t = tint / 100.0;
    color.g = clamp(color.g - t * 0.12, 0.0, 1.0);
    color.r = clamp(color.r + t * 0.06, 0.0, 1.0);
    color.b = clamp(color.b + t * 0.06, 0.0, 1.0);
    return color;
}

/// 对比度（围绕 0.5 缩放）
float3 applyContrast(float3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度（BT.709 亮度权重）
float3 applySaturation(float3 color, float saturation) {
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    return mix(float3(lum), color, saturation);
}

/// 黑场/白场偏移
float3 applyBlacksWhites(float3 color, float blacks, float whites) {
    float blacksOffset = blacks / 100.0 * (20.0 / 255.0);
    float whitesScale  = 1.0 + whites / 100.0 * 0.15;
    return clamp(color * whitesScale + blacksOffset, 0.0, 1.0);
}

/// 高光/阴影压缩（非线性曲线模拟）
float3 applyHighlightsShadows(float3 color, float highlights, float shadows) {
    float hScale  = 1.0 + highlights / 100.0 * 0.12;
    float hOffset = -highlights / 100.0 * 0.12 * (191.0 / 255.0);
    float sScale  = 1.0 - shadows / 100.0 * 0.08;
    float sOffset = shadows / 100.0 * 0.08 * (64.0 / 255.0) + shadows / 100.0 * (12.0 / 255.0);
    float scale   = hScale * sScale;
    float offset  = hOffset * sScale + sOffset;
    return clamp(color * scale + offset, 0.0, 1.0);
}

/// Clarity：中间调微对比度
float3 applyClarity(float3 color, float clarity) {
    float c      = clarity / 100.0;
    float boost  = 1.0 + c * 0.15;
    float offset = -c * 0.15 * 0.5;
    return clamp(color * boost + offset, 0.0, 1.0);
}

/// Vibrance：智能饱和度（低饱和区域优先提升，BT.709 权重）
float3 applyVibrance(float3 color, float vibrance) {
    float v   = vibrance / 100.0 * 0.6;
    float sat = 1.0 + v;
    const float lr = 0.2126;
    const float lg = 0.7152;
    const float lb = 0.0722;
    float sr = (1.0 - sat) * lr;
    float sg = (1.0 - sat) * lg;
    float sb = (1.0 - sat) * lb;
    return clamp(float3(
        color.r * (sr + sat) + color.g * sg + color.b * sb,
        color.r * sr + color.g * (sg + sat) + color.b * sb,
        color.r * sr + color.g * sg + color.b * (sb + sat)
    ), 0.0, 1.0);
}

/// RGB 通道偏移
float3 applyColorBias(float3 color, float r, float g, float b) {
    return clamp(color + float3(r * (30.0/255.0), g * (30.0/255.0), b * (30.0/255.0)), 0.0, 1.0);
}

// MARK: - CCD 风格片段着色器

fragment float4 ccdFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> lutTexture    [[texture(1)]],
    texture2d<float> grainTexture  [[texture(2)]],
    constant CCDParams &params     [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear,
                                     address_u::clamp_to_zero,
                                     address_v::clamp_to_zero);
    
    float2 uv = in.texCoord;

    // === Pass 0a: 镜头缩放（鱼眼视野扩展）===
    // zoomFactor < 1.0 时 UV 向外扩展，超出 [0,1] 的区域为黑色（圆形遮罩效果）
    // fisheye: zoomFactor=0.5 → 视野扩大 2x，形成圆形鱼眼外观
    // ultra_fisheye: zoomFactor=0.35 → 视野扩大 ~2.86x，更强烈的圆形效果
    if (params.zoomFactor > 0.001 && abs(params.zoomFactor - 1.0) > 0.001) {
        uv = applyZoom(uv, params.zoomFactor);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    // === Pass 0b: 镜头畸变（Brown-Conrady 径向畸变）===
    // params.distortion 直接映射到 k1（Brown-Conrady 系数）
    // 鱼眼 distortion=-0.60 → k1=-0.45（强桶形，图像向外鼓）
    // 广角 distortion=-0.08 → k1=-0.06（轻微桶形）
    // 长焦 distortion=+0.05 → k1=+0.0375（轻微枕形）
    float k1 = params.distortion * 0.75;
    uv = applyLensDistortion(uv, k1);
    // 边缘裁切：畸变后 UV 超出 [0,1] 的区域填充黑色
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // === Pass 1: 色差 (Chromatic Aberration) ===
    float ca = params.chromaticAberration;
    float r  = cameraTexture.sample(textureSampler, uv + float2(ca, 0.0)).r;
    float g  = cameraTexture.sample(textureSampler, uv).g;
    float b  = cameraTexture.sample(textureSampler, uv - float2(ca, 0.0)).b;
    float3 color = float3(r, g, b);
    
    // === Pass 1.5: 曝光偏移（在色彩处理之前应用，模拟胶片曝光量）===
    if (abs(params.exposureOffset) > 0.001) {
        color = applyExposure(color, params.exposureOffset);
    }

    // === Pass 2: 色温 + Tint ===
    color = applyTemperatureShift(color, params.temperatureShift);
    color = applyTint(color, params.tintShift);
    
    // === Pass 3: 黑场/白场 ===
    color = applyBlacksWhites(color, params.blacks, params.whites);
    
    // === Pass 4: 高光/阴影压缩 ===
    color = applyHighlightsShadows(color, params.highlights, params.shadows);
    
    // === Pass 5: 对比度 ===
    color = applyContrast(color, params.contrast);
    
    // === Pass 6: Clarity（中间调微对比度）===
    if (abs(params.clarity) > 0.5) {
        color = applyClarity(color, params.clarity);
    }
    
    // === Pass 7: 饱和度 + Vibrance ===
    color = applySaturation(color, params.saturation);
    if (abs(params.vibrance) > 0.5) {
        color = applyVibrance(color, params.vibrance);
    }
    
    // === Pass 8: RGB 通道偏移 ===
    if (abs(params.colorBiasR) + abs(params.colorBiasG) + abs(params.colorBiasB) > 0.001) {
        color = applyColorBias(color, params.colorBiasR, params.colorBiasG, params.colorBiasB);
    }
    
    // === Pass 9: 高光溢出 (Bloom / Halation) ===
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (luminance > 0.8 && params.bloomAmount > 0.0) {
        float bloom = (luminance - 0.8) * params.bloomAmount * 2.0;
        color = clamp(color + float3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }
    
    // === Pass 10: 胶片颗粒 (Grain) ===
    if (params.grainAmount > 0.0) {
        float3 grain = grainTexture.sample(textureSampler, uv * 2.0).rgb;
        color = clamp(color + (grain - 0.5) * params.grainAmount * 0.3, 0.0, 1.0);
    }
    
    // === Pass 11: 动态数字噪点 (Noise) ===
    if (params.noiseAmount > 0.0) {
        float noise = random(uv, params.time) - 0.5;
        float darkMask = 1.0 - luminance;
        color = clamp(color + noise * params.noiseAmount * 0.2 * darkMask, 0.0, 1.0);
    }
    
    // === Pass 12: 暗角 (Vignette) ===
    // preset 暗角 + 镜头层暗角叠加，上限 1.0
    float vigTotal = min(params.vignetteAmount + params.lensVignette, 1.0);
    float vignette = vignetteEffect(uv, vigTotal);
    color *= vignette;
    
    return float4(color, 1.0);
}
