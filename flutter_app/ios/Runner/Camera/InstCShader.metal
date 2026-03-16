// InstCShader.metal
// DAZZ Camera — Inst C (Fujifilm Instax Mini 风格即时成像机)
//
// ═══════════════════════════════════════════════════════════════════════════
// 风格定位：
//   Fujifilm Instax Mini 即时成像胶片模拟
//   社区定义：digital Polaroid / instant nostalgia / Instax Mini output
//
// 核心特征（基于 Instax Mini 真实相机特性）：
//   1. 低到中对比（contrast=0.92）
//   2. 轻冷白平衡（temperature=-20，Instax 偏冷白）
//   3. 轻微洋红（tint=+6）
//   4. 高光柔和 rolloff（highlightRolloff=0.20）
//   5. 轻微不均匀曝光（edgeFalloff=0.05, exposureVariation=0.04）
//   6. 轻纸感纹理（paperTexture=0.06）
//   7. 轻颗粒（grain=0.08，非胶片重颗粒）
//   8. 内置闪光灯中心增亮（centerGain=0.02，比 SQC 更自然）
//   9. 化学显影柔化（developmentSoftness=0.03，Mini 显影更稳定）
//  10. 化学不规则感（chemicalIrregularity=0.015，Mini 胶片面积小更均匀）
//  11. 肤色保护系统（skinHueProtect=true，Mini 肤色偏粉嫩非橙）
//
// GPU Pipeline 顺序（18 pass）：
//   Camera Frame
//   → Chromatic Aberration（极轻色差）
//   → White Balance（色温 + Tint）
//   → Tone Curve（Instax 胶片曲线）
//   → RGB Channel Shift（暖调色偏）
//   → Saturation + Contrast
//   → Highlight Rolloff（高光柔和滴落）
//   → Soft Bloom（轻柔光）
//   → Halation（极轻高光发光）
//   → Center Gain（中心增亮，内置闪光灯特征）
//   → Fine Grain（轻颗粒）
//   → Paper Texture（相纸纹理）
//   → Edge Falloff / Uneven Exposure（不均匀曝光）
//   → Corner Warm Shift（边角偏暖）
//   → Development Softness（显影柔化）
//   → Chemical Irregularity（化学不规则感）
//   → Skin Protection（肤色保护）
//   → Vignette（极轻暗角）
//   → Output
//
// ⚠️  InstCParams 字段顺序必须与 Swift 侧 buffer 布局完全一致
// ⚠️  新增字段只能追加到末尾
// ═══════════════════════════════════════════════════════════════════════════

#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点着色器

struct InstCVertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct InstCVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex InstCVertexOut instcVertexShader(InstCVertexIn in [[stage_in]]) {
    InstCVertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

// MARK: - Inst C Uniform 参数
/// ⚠️ InstCParams 字段顺序必须与 Swift 侧 CCDParams buffer 布局完全一致
/// 字段顺序：通用字段（与 CCDParams 相同）→ FQS/CPM35 字段 → Inst C 嬓用字段
struct InstCParams {
    // ── 通用参数（与 CCDParams 字段顺序完全相同）────────────────────────────
    float contrast;            // 对比度倍数（Inst C=0.92）
    float saturation;          // 饱和度倍数（Inst C=1.08）
    float temperatureShift;    // 色温偏移（Inst C=+6400，偏暖）
    float tintShift;           // 色调偏移（Inst C=+6，轻微洋红）
    float grainAmount;         // 颗粒强度（Inst C=0.08，轻颗粒）
    float noiseAmount;         // 通用噪声量（Inst C 不使用）
    float vignetteAmount;      // 暗角强度（Inst C=0.06，极轻）
    float chromaticAberration; // 色差强度（Inst C=0.05）
    float bloomAmount;         // 柔光强度（Inst C=0.06）
    float halationAmount;      // 高光发光强度（Inst C=0.02，极轻）
    float sharpen;             // 锐化（Inst C=-0.02，略微柔化）
    float blurRadius;          // 模糊半径（Inst C 不使用）
    float jpegArtifacts;       // JPEG 噪点（Inst C 不使用）
    float time;                // 时间种子（每帧更新）
    float fisheyeMode;         // 鱼眼模式（Inst C 不使用）
    float aspectRatio;         // 宽高比
    // ── FQS/CPM35 共用字段（Inst C 也使用其中的 colorBias/grainSize/sharpness）─────────
    float colorBiasR;          // R 通道偏移（Inst C=+0.022，轻微暖红）
    float colorBiasG;          // G 通道偏移（Inst C=+0.010，轻微绿）
    float colorBiasB;          // B 通道偏移（Inst C=-0.015，去蓝暖调）
    float grainSize;           // 颗粒大小（Inst C=1.8）
    float sharpness;           // 锐度倍数（Inst C=0.98，略微柔化）
    float highlightWarmAmount; // CPM35 暖高光推送（Inst C 不使用）
    float luminanceNoise;      // 亮度噪声（Inst C 不使用）
    float chromaNoise;         // 色度噪声（Inst C 不使用）
    // ── 拍立得即时成像专属字段（追加在 CCDParams 末尾，Inst C / SQC 通用）────
    float highlightRolloff;     // 高光柔和滴落强度（Inst C=0.20）
    float paperTexture;         // 相纸纹理强度（Inst C=0.06）
    float edgeFalloff;          // 边缘曝光衰减（不均匀曝光，Inst C=0.05）
    float exposureVariation;    // 全局曝光不均匀幅度（Inst C=0.04）
    float cornerWarmShift;      // 边角偏暖强度（Inst C=0.02）
    float centerGain;           // 中心增亮（内置闪光灯，Inst C=0.02）
    float developmentSoftness;  // 显影柔化（化学扩散，Inst C=0.03）
    float chemicalIrregularity; // 化学不规则感（Inst C=0.015）
    float skinHueProtect;       // 肤色色相保护（1.0=开启，Inst C=1.0）
    float skinSatProtect;       // 肤色饱和度保护（Inst C=0.92）
    float skinLumaSoften;       // 肤色亮度柔化（Inst C=0.05）
    float skinRedLimit;         // 肤色红限（Inst C=1.02）
};

// MARK: - 工具函数

/// 伪随机数生成（基于 UV + 时间种子）
float instcRandom(float2 uv, float seed) {
    return fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123);
}

/// Inst C Tone Curve（Instax 胶片曲线）
/// 控制点（归一化）：(0, 0.024) (0.125, 0.133) (0.251, 0.267) (0.502, 0.510) (0.753, 0.792) (1.0, 0.973)
/// 对应原始值：0→6, 32→34, 64→68, 128→130, 192→202, 255→248
/// 效果：黑位抬一点，中间调偏软，高光轻 rolloff，更像即时成像
float instcToneCurve(float x) {
    // 分段三次平滑插值（5 段）
    if (x < 0.125) {
        // 段 1: [0, 0.125] → [0.024, 0.133]
        float t = x / 0.125;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.024 + (0.133 - 0.024) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.251) {
        // 段 2: [0.125, 0.251] → [0.133, 0.267]
        float t = (x - 0.125) / 0.126;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.133 + (0.267 - 0.133) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.502) {
        // 段 3: [0.251, 0.502] → [0.267, 0.510]
        float t = (x - 0.251) / 0.251;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.267 + (0.510 - 0.267) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.753) {
        // 段 4: [0.502, 0.753] → [0.510, 0.792]
        float t = (x - 0.502) / 0.251;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.510 + (0.792 - 0.510) * (3.0 * t2 - 2.0 * t3);
    } else {
        // 段 5: [0.753, 1.0] → [0.792, 0.973]（高光轻 rolloff）
        float t = (x - 0.753) / 0.247;
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.792 + (0.973 - 0.792) * (3.0 * t2 - 2.0 * t3);
    }
}

/// 饱和度调整（HSL 空间）
float3 instcSaturation(float3 color, float saturation) {
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(lum), color, saturation), 0.0, 1.0);
}

/// 对比度调整（以 0.5 为中心）
float3 instcContrast(float3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 色温 + Tint 调整（Instax 偏冷白）
/// temperature: 正值偏暖，负值偏冷（范围 -200~+200）
/// Instax 实际偏冷白，所以 temperature = -20
/// tint: 正值偏洋红（R+, G-）
float3 instcTemperatureTint(float3 color, float temperature, float tint) {
    // 色温：正值 = 偏暖（加R减B），负值 = 偏冷（减R加B）
    float tempFactor = temperature / 1000.0;  // -20 → -0.02
    color.r = clamp(color.r + tempFactor * 0.30, 0.0, 1.0);
    color.g = clamp(color.g + tempFactor * 0.05, 0.0, 1.0);
    color.b = clamp(color.b - tempFactor * 0.25, 0.0, 1.0);
    // Tint：正值偏洋红（R+, G-）
    float tintFactor = tint / 1000.0;  // +6 → +0.006
    color.r = clamp(color.r + tintFactor * 0.5, 0.0, 1.0);
    color.g = clamp(color.g - tintFactor * 0.3, 0.0, 1.0);
    color.b = clamp(color.b + tintFactor * 0.1, 0.0, 1.0);
    return color;
}

/// Highlight Rolloff（高光柔和滴落）
/// 将高光区域（lum > 0.7）柔和压缩，避免过曝死白
float3 instcHighlightRolloff(float3 color, float rolloff) {
    if (rolloff < 0.001) return color;
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (lum > 0.70) {
        // 高光区域：平滑压缩到 [0.70, 0.95]
        float mask = clamp((lum - 0.70) / 0.30, 0.0, 1.0);
        mask = mask * mask * (3.0 - 2.0 * mask);  // smoothstep
        // 压缩高光（偏暖：R 保留更多，B 压缩更多）
        float3 compressed = float3(
            color.r * (1.0 - mask * rolloff * 0.15),
            color.g * (1.0 - mask * rolloff * 0.20),
            color.b * (1.0 - mask * rolloff * 0.30)
        );
        color = mix(color, compressed, mask * rolloff);
    }
    return clamp(color, 0.0, 1.0);
}

/// Vignette（暗角，Instax 极轻）
float instcVignette(float2 uv, float amount) {
    float2 center = uv - 0.5;
    float dist = length(center * float2(1.0, 1.3));  // 椭圆形暗角
    float vignette = 1.0 - smoothstep(0.3, 0.85, dist * 1.8);
    return mix(1.0, vignette, amount);
}

/// Edge Falloff（边缘曝光衰减，模拟 Instax 不均匀曝光）
/// 四周轻微暗，中心稍亮，模拟即时成像的不均匀化学显影
float instcEdgeFalloff(float2 uv, float amount, float time) {
    if (amount < 0.001) return 1.0;
    float2 center = uv - 0.5;
    // 基础边缘衰减（椭圆形）
    float edgeDist = dot(center * float2(1.2, 1.0), center * float2(1.2, 1.0));
    float falloff = 1.0 - smoothstep(0.10, 0.35, edgeDist);
    // 轻微不均匀（低频噪声模拟化学显影不均）
    float variation = instcRandom(uv * 0.3, floor(time * 0.1)) * 2.0 - 1.0;
    variation *= 0.3;  // 降低不均匀幅度
    falloff = clamp(falloff + variation * amount * 0.5, 0.6, 1.0);
    return mix(1.0, falloff, amount * 1.5);
}

/// Corner Warm Shift（边角偏暖，Instax 化学显影边缘特征）
float3 instcCornerWarm(float3 color, float2 uv, float amount) {
    if (amount < 0.001) return color;
    float2 center = uv - 0.5;
    float dist = length(center);
    float cornerMask = smoothstep(0.25, 0.55, dist);
    // 边角偏暖：R+, B-
    color.r = clamp(color.r + cornerMask * amount * 0.08, 0.0, 1.0);
    color.b = clamp(color.b - cornerMask * amount * 0.06, 0.0, 1.0);
    return color;
}

/// Paper Texture（相纸纹理，模拟 Instax 相纸表面微纹理）
float3 instcPaperTexture(float3 color, float2 uv, float amount, float time) {
    if (amount < 0.001) return color;
    float2 paperUV1 = uv * 8.0;
    float2 paperUV2 = uv * 32.0;
    float paper1 = instcRandom(paperUV1, 0.0) * 2.0 - 1.0;
    float paper2 = instcRandom(paperUV2, 1.0) * 2.0 - 1.0;
    float paper = paper1 * 0.7 + paper2 * 0.3;
    float3 paperColor = color + float3(paper * amount * 0.04);
    return clamp(paperColor, 0.0, 1.0);
}

/// Center Gain（中心增亮，模拟 Instax 内置闪光灯中心亮度略高）
/// Inst C=0.02（比 SQC=0.03 更自然，Mini 闪光灯功率较小）
float3 instcCenterGain(float3 color, float2 uv, float amount) {
    if (amount < 0.001) return color;
    float2 center = uv - 0.5;
    float dist = length(center * float2(1.0, 1.1));  // 轻微椭圆（横向略宽）
    float centerMask = 1.0 - smoothstep(0.0, 0.45, dist);
    centerMask = centerMask * centerMask;
    // 中心增亮：偏暖白（模拟闪光灯色温约 5500K）
    float3 gainColor = float3(
        color.r * (1.0 + centerMask * amount * 1.2),
        color.g * (1.0 + centerMask * amount * 1.0),
        color.b * (1.0 + centerMask * amount * 0.7)
    );
    return clamp(gainColor, 0.0, 1.0);
}

/// Development Softness（显影柔化，模拟 Instax 化学显影扩散）
/// Inst C=0.03（比 SQC=0.04 更克制，Mini 显影过程更稳定）
float3 instcDevelopmentSoftness(float3 color, float2 uv, float amount,
                                 texture2d<float> tex, sampler s) {
    if (amount < 0.001) return color;
    float offset = amount * 0.004;  // 比 SQC 的 0.005 更小
    float3 c = tex.sample(s, uv).rgb;
    float3 up    = tex.sample(s, uv + float2(0.0,  offset)).rgb;
    float3 down  = tex.sample(s, uv + float2(0.0, -offset)).rgb;
    float3 left  = tex.sample(s, uv + float2(-offset, 0.0)).rgb;
    float3 right = tex.sample(s, uv + float2( offset, 0.0)).rgb;
    float3 blurred = c * 0.5 + up * 0.125 + down * 0.125 + left * 0.125 + right * 0.125;
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    float softMask = 1.0 - abs(lum - 0.5) * 1.5;
    softMask = clamp(softMask, 0.0, 1.0) * amount * 3.0;
    return clamp(mix(color, blurred, softMask), 0.0, 1.0);
}

/// Chemical Irregularity（化学不规则感，模拟 Instax 胶片化学分布不均）
/// Inst C=0.015（比 SQC=0.02 更低，Mini 胶片面积小化学分布更均匀）
float3 instcChemicalIrregularity(float3 color, float2 uv, float amount, float time) {
    if (amount < 0.001) return color;
    float2 irregUV = uv * 2.5;
    float irreg1 = instcRandom(irregUV, floor(time * 0.1) * 0.1) * 2.0 - 1.0;
    float irreg2 = instcRandom(irregUV * 1.7 + 0.3, floor(time * 0.1) * 0.2) * 2.0 - 1.0;
    float irregularity = irreg1 * 0.6 + irreg2 * 0.4;
    float brightVar = irregularity * amount * 0.03;
    float3 colorShift = float3(
        irregularity * amount * 0.008,
        irregularity * amount * 0.004,
        -irregularity * amount * 0.006
    );
    return clamp(color + float3(brightVar) + colorShift, 0.0, 1.0);
}

/// Skin Protection（肤色保护系统）
/// Inst C：skinSatProtect=0.92，skinLumaSoften=0.05，skinRedLimit=1.02
/// Mini 肤色偏粉嫩而非橙，比 SQC 更严格防止过红
float3 instcSkinProtect(float3 color, float skinHueProtect,
                         float skinSatProtect, float skinLumaSoften, float skinRedLimit) {
    if (skinHueProtect < 0.5) return color;
    float maxC = max(max(color.r, color.g), color.b);
    float minC = min(min(color.r, color.g), color.b);
    float delta = maxC - minC;
    float lum = (maxC + minC) * 0.5;
    float sat = (delta < 0.001) ? 0.0 : delta / (1.0 - abs(2.0 * lum - 1.0));
    float hue = 0.0;
    if (delta > 0.001) {
        if (maxC == color.r)      hue = fmod((color.g - color.b) / delta, 6.0);
        else if (maxC == color.g) hue = (color.b - color.r) / delta + 2.0;
        else                      hue = (color.r - color.g) / delta + 4.0;
        hue = hue / 6.0;
        if (hue < 0.0) hue += 1.0;
    }
    // 肤色检测：Hue 0~50°（0.0~0.139），Sat 0.15~0.85，Lum 0.2~0.85
    bool isSkin = (hue >= 0.0 && hue <= 0.139) &&
                  (sat >= 0.15 && sat <= 0.85) &&
                  (lum >= 0.20 && lum <= 0.85);
    if (!isSkin) return color;
    float hueMask  = 1.0 - smoothstep(0.10, 0.139, hue);
    float satMask  = smoothstep(0.15, 0.25, sat) * (1.0 - smoothstep(0.75, 0.85, sat));
    float lumMask  = smoothstep(0.20, 0.35, lum) * (1.0 - smoothstep(0.75, 0.85, lum));
    float skinMask = hueMask * satMask * lumMask;
    float3 result = color;
    // 1. 饱和度保护：防止肤色过饱和变橙
    float lumVal = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 desat = mix(float3(lumVal), color, skinSatProtect);
    result = mix(result, desat, skinMask * 0.6);
    // 2. 亮度柔化：Instax Mini 肤色有轻微发光感
    float lumBoost = lum * skinLumaSoften * 0.8;
    result = clamp(result + float3(lumBoost), 0.0, 1.0);
    // 3. 红限：防止肤色过红（Inst C=1.02，比 SQC=1.03 更严格）
    result.r = clamp(result.r, 0.0, skinRedLimit);
    return clamp(mix(color, result, skinMask), 0.0, 1.0);
}

// MARK: - Inst C 片段着色器

fragment float4 instcFragmentShader(
    InstCVertexOut in           [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> grainTexture  [[texture(2)]],
    constant InstCParams &params   [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    float2 uv = in.texCoord;

    // ── Pass 1: 采样（Inst C 色差极轻，仅在 chromaticAberration > 0 时启用）
    float3 color;
    if (params.chromaticAberration > 0.001) {
        float ca = params.chromaticAberration * 0.008;  // 比 FQS 更轻
        float r = cameraTexture.sample(s, uv + float2(ca,  0.0)).r;
        float g = cameraTexture.sample(s, uv).g;
        float b = cameraTexture.sample(s, uv - float2(ca,  0.0)).b;
        color = float3(r, g, b);
    } else {
        color = cameraTexture.sample(s, uv).rgb;
    }

    // ── Pass 2: 白平衡（色温 + Tint，Instax 轻暖调）────────────────────────
    color = instcTemperatureTint(color, params.temperatureShift, params.tintShift);

    // ── Pass 3: Tone Curve（Instax 胶片曲线）────────────────────────────────
    // 分通道应用，保留 Instax 轻微色偏
    color.r = instcToneCurve(color.r);
    color.g = instcToneCurve(color.g);
    color.b = instcToneCurve(color.b);

    // ── Pass 4: RGB Channel Shift（Instax 暖调色偏）─────────────────────────
    // R+2.2%, G+1.0%, B-1.5%（轻微暖调，比 FQS 更温和）
    color.r = clamp(color.r * (1.0 + params.colorBiasR), 0.0, 1.0);
    color.g = clamp(color.g * (1.0 + params.colorBiasG), 0.0, 1.0);
    color.b = clamp(color.b * (1.0 + params.colorBiasB), 0.0, 1.0);

    // ── Pass 5: 饱和度（1.08，Instax 色彩略浓）──────────────────────────────
    color = instcSaturation(color, params.saturation);

    // ── Pass 6: 对比度（0.92，低对比 Instax 感）─────────────────────────────
    color = instcContrast(color, params.contrast);

    // ── Pass 7: Highlight Rolloff（高光柔和滴落，Inst C 核心特征）──────────
    color = instcHighlightRolloff(color, params.highlightRolloff);

    // ── Pass 8: Soft Bloom（轻柔光，高光偏柔）───────────────────────────────
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (params.bloomAmount > 0.001 && lum > 0.75) {
        float bloom = clamp((lum - 0.75) * params.bloomAmount * 2.5, 0.0, 0.25);
        // Instax bloom 偏暖白（R > G > B）
        color = clamp(color + float3(bloom * 0.9, bloom * 0.8, bloom * 0.6), 0.0, 1.0);
    }

    // ── Pass 9: Halation（极轻高光发光，Inst C=0.02）────────────────────────
    if (params.halationAmount > 0.001 && lum > 0.80) {
        float halationMask = clamp((lum - 0.80) / 0.20, 0.0, 1.0);
        halationMask = halationMask * halationMask;
        // Instax halation 偏暖白（不像胶片那么红）
        float3 halationColor = float3(
            color.r * 1.08,
            color.g * 1.02,
            color.b * 0.95
        );
        color = mix(color, halationColor, halationMask * params.halationAmount);
    }

    // ── Pass 10: Fine Grain（轻颗粒，grain_color=false，Instax 不该有重颗粒）
    if (params.grainAmount > 0.001) {
        float timeSeed = floor(params.time * 24.0) / 24.0;
        // 从噪点纹理采样
        float2 grainUV = uv * max(params.grainSize, 0.1);
        float grainTex = grainTexture.sample(s, grainUV).r;
        float dynamicGrain = instcRandom(uv, timeSeed) - 0.5;
        // 混合纹理颗粒和程序颗粒（8:2，Instax 更均匀）
        float grain = mix(grainTex - 0.5, dynamicGrain, 0.2);
        // 颗粒强度随亮度变化（中间调最明显）
        float grainLum = dot(color, float3(0.2126, 0.7152, 0.0722));
        float grainMask = 1.0 - abs(grainLum - 0.50) * 1.0;
        grainMask = clamp(grainMask, 0.2, 1.0);
        // 亮度颗粒（grain_color=false，Instax 颗粒不彩色）
        color = clamp(color + float3(grain) * params.grainAmount * 0.18 * grainMask,
                      0.0, 1.0);
    }

    // ── Pass 11: Paper Texture（相纸纹理，Instax 相纸表面微纹理）────────────
    color = instcPaperTexture(color, uv, params.paperTexture, params.time);

    // ── Pass 12: Edge Falloff / Uneven Exposure（不均匀曝光，Inst C 核心特征）
    float edgeFactor = instcEdgeFalloff(uv, params.edgeFalloff, params.time);
    color *= edgeFactor;

    // ── Pass 13: Corner Warm Shift（边角偏暖，Instax 化学显影边缘特征）──────
    color = instcCornerWarm(color, uv, params.cornerWarmShift);

    // ── Pass 14: Development Softness（显影柔化，Inst C=0.03）───────────────
    color = instcDevelopmentSoftness(color, uv, params.developmentSoftness,
                                      cameraTexture, s);

    // ── Pass 15: Chemical Irregularity（化学不规则感，Inst C=0.015）─────────
    color = instcChemicalIrregularity(color, uv, params.chemicalIrregularity, params.time);

    // ── Pass 16: Skin Protection（肤色保护，Inst C 偏粉嫩）──────────────────
    color = instcSkinProtect(color, params.skinHueProtect,
                              params.skinSatProtect, params.skinLumaSoften,
                              params.skinRedLimit);

    // ── Pass 17: Center Gain（中心增亮，内置闪光灯特征，Inst C=0.02）────────
    color = instcCenterGain(color, uv, params.centerGain);

    // ── Pass 18: Vignette（极轻暗角，Inst C=0.06）───────────────────────────
    if (params.vignetteAmount > 0.001) {
        color *= instcVignette(uv, params.vignetteAmount);
    }

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
