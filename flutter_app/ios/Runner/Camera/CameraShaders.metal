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

// 注意：字段顺序必须与 Swift 侧 MetalRenderer.swift 中的 CCDParams 完全一致！
struct CCDParams {
    // ── 通用参数（所有相机共用）──────────────────────────────────────
    float contrast;
    float saturation;
    float temperatureShift;
    float tintShift;
    float grainAmount;
    float noiseAmount;
    float vignetteAmount;
    float chromaticAberration;
    float bloomAmount;
    float halationAmount;
    float sharpen;
    float blurRadius;
    float jpegArtifacts;
    float time;
    float fisheyeMode;
    float aspectRatio;
    // ── FQS / CPM35 专用扩展字段─────────────────────────────────────────────────────
    float colorBiasR;
    float colorBiasG;
    float colorBiasB;
    float grainSize;
    float sharpness;
    float highlightWarmAmount;
    float luminanceNoise;
    float chromaNoise;
    // ── Inst C 专用扩展字段──────────────────────────────────────────────────────────────
    float highlightRolloff;
    float paperTexture;
    float edgeFalloff;
    float exposureVariation;
    float cornerWarmShift;
    // ── 拍立得通用扩展字段（Inst C / SQC 共用）───────────────────────────────────────
    float centerGain;
    float developmentSoftness;
    float chemicalIrregularity;
    float skinHueProtect;
    float skinSatProtect;
    float skinLumaSoften;
    float skinRedLimit;
    // ── Lightroom 风格曲线参数（新增字段，追加到末尾）─────────────────────────────────
    float highlights;
    float shadows;
    float whites;
    float blacks;
    float clarity;
    float vibrance;
    float noiseAmountExtra;  // 对应 Swift 侧第二个 noiseAmount 字段（预留，内容与 noiseAmount 相同）
    // ── LUT + ToneCurve 参数（新增字段，追加到末尾）─────────────────────────────────
    float lutEnabled;        // 1.0=启用 LUT，0.0=跳过
    float lutSize;           // LUT 尺寸（通常 33 或 64）
    float lutStrength;       // LUT 混合强度（0.0~1.0）
    float toneCurveStrength; // Tone Curve 强度（0.0~1.0）
    float exposureOffset;    // 用户曝光补偿（-2.0~+2.0）
    float lensDistortion;    // 轻量桶形畸变（非圆形鱼眼）
    // ── Device Calibration（V3：设备级线性校准）─────────────────────────────────
    float deviceGamma;
    float deviceWhiteScaleR;
    float deviceWhiteScaleG;
    float deviceWhiteScaleB;
    float deviceCcm00;
    float deviceCcm01;
    float deviceCcm02;
    float deviceCcm10;
    float deviceCcm11;
    float deviceCcm12;
    float deviceCcm20;
    float deviceCcm21;
    float deviceCcm22;
    float circularFisheye;
};

// MARK: - 工具函数

/// 计算暗角强度
float vignetteEffect(float2 uv, float amount) {
    float2 d = uv - 0.5;
    float dist = length(d) * 2.0;
    return 1.0 - smoothstep(1.0 - amount, 1.5, dist) * amount;
}

/// 简单的伪随机噪点生成
float random(float2 st, float seed) {
    return fract(sin(dot(st + seed, float2(12.9898, 78.233))) * 43758.5453);
}

/// 色温偏移（简化版，将色温变化映射到 RGB 偏移）
/// 正值 = 偏暖（加R减B），负值 = 偏冷（减R加B）
/// shift 范围 -200~+200，/1000 后约 ±0.2
float3 applyTemperatureShift(float3 color, float shift) {
    float normalizedShift = shift / 1000.0;
    color.r = clamp(color.r + normalizedShift * 0.3, 0.0, 1.0);
    color.b = clamp(color.b - normalizedShift * 0.3, 0.0, 1.0);
    return color;
}

/// 对比度调整
float3 applyContrast(float3 color, float contrast) {
    return clamp((color - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// 饱和度调整
float3 applySaturation(float3 color, float saturation) {
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    return mix(float3(luminance), color, saturation);
}

/// Unsharp Mask 锐化
/// 原理：sharpen(x) = original + strength * (original - blur)
/// 使用 3x3 高斯模糊近似作为 blur
float3 applySharpen(
    texture2d<float> tex,
    sampler s,
    float2 uv,
    float2 texelSize,
    float amount
) {
    float3 center = tex.sample(s, uv).rgb;

    // 3x3 高斯核（权重归一化）
    // [ 1 2 1 ]
    // [ 2 4 2 ] / 16
    // [ 1 2 1 ]
    float3 blur =
        tex.sample(s, uv + float2(-texelSize.x, -texelSize.y)).rgb * 1.0 +
        tex.sample(s, uv + float2( 0.0,         -texelSize.y)).rgb * 2.0 +
        tex.sample(s, uv + float2( texelSize.x, -texelSize.y)).rgb * 1.0 +
        tex.sample(s, uv + float2(-texelSize.x,  0.0        )).rgb * 2.0 +
        center                                                       * 4.0 +
        tex.sample(s, uv + float2( texelSize.x,  0.0        )).rgb * 2.0 +
        tex.sample(s, uv + float2(-texelSize.x,  texelSize.y)).rgb * 1.0 +
        tex.sample(s, uv + float2( 0.0,          texelSize.y)).rgb * 2.0 +
        tex.sample(s, uv + float2( texelSize.x,  texelSize.y)).rgb * 1.0;
    blur /= 16.0;

    // amount 范围 0~1，映射到实际锐化强度 0~2.0
    float strength = amount * 2.0;
    return clamp(center + strength * (center - blur), 0.0, 1.0);
}

// MARK: - 圆形鱼眼投影

/// 等距投影：将屏幕像素映射到球面，圆形以外返回 float2(-1)
/// r=1 对应 90° FOV 边缘，产生强烈桶形畸变
float2 fisheyeUV(float2 uv, float aspect) {
    float2 p = (uv - 0.5) * 2.0;
    p.x *= aspect; // 修正宽高比使圆形不变形
    float r = length(p);
    // 缩小有效圆半径，让鱼眼“圆边界”更明显。
    constexpr float rMax = 0.98;
    if (r > rMax) return float2(-1.0); // 圆外标记
    float rn = r / rMax;
    // 等距投影：theta = r * (π/2)
    float theta = rn * 1.5707963; // M_PI_F / 2
    float phi = atan2(p.y, p.x);
    float sinTheta = sin(theta);
    float2 texCoord = float2(
        sinTheta * cos(phi),
        sinTheta * sin(phi)
    );
    return texCoord * 0.5 + 0.5;
}

float2 fisheyeRectUV(float2 uv, float aspect) {
    float2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r = length(p);
    float rCorner = length(float2(aspect, 1.0));
    float rn = clamp(r / max(rCorner, 0.0001), 0.0, 1.0);
    float theta = rn * 1.5707963;
    float phi = atan2(p.y, p.x);
    float sinTheta = sin(theta);
    float2 mapped = float2(sinTheta * cos(phi), sinTheta * sin(phi));
    mapped.x /= max(aspect, 0.0001);
    return clamp(mapped * 0.5 + 0.5, float2(0.0), float2(1.0));
}

float2 barrelDistortUV(float2 uv, float strength, float aspect) {
    float2 p = (uv - 0.5) * 2.0;
    p.x *= aspect;
    float r2 = dot(p, p);
    float k = 1.0 + strength * 0.35 * r2;
    p *= k;
    p.x /= max(aspect, 0.0001);
    return p * 0.5 + 0.5;
}

// MARK: - 传感器非均匀性工具函数

/// 中心增亮 + 边缘衰减（模拟镜头光学特性）
float ccdCenterEdge(float2 uv, float centerGain, float edgeFalloff) {
    float2 d = uv - 0.5;
    float dist = length(d);
    float center = 1.0 + centerGain * (1.0 - dist * 2.0);
    float edge   = 1.0 - edgeFalloff * dist * dist * 4.0;
    return clamp(center * edge, 0.5, 1.5);
}

/// 角落色温偏移（负値=偏冷青，FXN-R=-0.015）
float3 ccdCornerWarm(float2 uv, float3 color, float shift) {
    float2 d = uv - 0.5;
    float cornerFactor = clamp(dot(d, d) * 4.0, 0.0, 1.0);
    float s = shift * cornerFactor;
    color.r = clamp(color.r + s * 0.4, 0.0, 1.0);
    color.b = clamp(color.b - s * 0.4, 0.0, 1.0);
    return color;
}

/// 显影柔化（轻微高斯模糊，模拟传感器低通滤波）
float3 ccdDevelopmentSoften(
    texture2d<float> tex, sampler s, float2 uv, float2 texelSize, float3 color, float softness
) {
    if (softness <= 0.0) return color;
    float3 blurred =
        tex.sample(s, uv + float2(-texelSize.x, 0.0)).rgb * 0.25 +
        tex.sample(s, uv + float2( texelSize.x, 0.0)).rgb * 0.25 +
        tex.sample(s, uv + float2(0.0, -texelSize.y)).rgb * 0.25 +
        tex.sample(s, uv + float2(0.0,  texelSize.y)).rgb * 0.25;
    return mix(color, blurred, softness * 0.5);
}

/// RGB → HSL（用于肤色检测）
float3 ccdRgbToHsl(float3 rgb) {
    float maxC = max(max(rgb.r, rgb.g), rgb.b);
    float minC = min(min(rgb.r, rgb.g), rgb.b);
    float delta = maxC - minC;
    float l = (maxC + minC) * 0.5;
    float s = (delta < 0.001) ? 0.0 : delta / (1.0 - abs(2.0 * l - 1.0));
    float h = 0.0;
    if (delta > 0.001) {
        if (maxC == rgb.r)      h = fmod((rgb.g - rgb.b) / delta, 6.0);
        else if (maxC == rgb.g) h = (rgb.b - rgb.r) / delta + 2.0;
        else                    h = (rgb.r - rgb.g) / delta + 4.0;
        h = h / 6.0;
        if (h < 0.0) h += 1.0;
    }
    return float3(h, s, l);
}

/// 肤色保护（防止冷 LUT 让肤色发青）
/// 肤色 hue 范围：20°~45°（归一化 0.0556~0.125）
float3 ccdSkinProtect(
    float3 color, float skinHueProtect, float skinSatProtect, float skinLumaSoften, float skinRedLimit
) {
    if (skinHueProtect < 0.5) return color;
    float3 hsl = ccdRgbToHsl(color);
    float hue = hsl.x;
    float skinMask = smoothstep(0.0356, 0.0756, hue) * (1.0 - smoothstep(0.105, 0.145, hue));
    if (skinMask < 0.001) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 prot = mix(float3(luma), color, skinSatProtect);
    prot = clamp(prot + skinLumaSoften * 0.1, 0.0, 1.0);
    prot.r = clamp(prot.r, 0.0, skinRedLimit);
    return mix(color, prot, skinMask);
}

// MARK: - LUT / Tone Curve / Highlight Rolloff 工具函数

/// 3D LUT 采样（支持任意边长，常用 33x33x33）
/// LUT 纹理布局：将 3D 坐标折叠为 2D 行列（每行 = B 层，每列 = G*N+R）
float3 sampleLUT(
    texture2d<float> lut,
    sampler s,
    float3 color,
    float lutN  // LUT 边长，常用 33.0
) {
    float scale = (lutN - 1.0) / lutN;
    float offset = 0.5 / lutN;
    float3 lutCoord = color * scale + offset;

    // 将 3D 坐标映射到 2D 纹理：宽 = N*N，高 = N
    float bSlice  = lutCoord.b * (lutN - 1.0);
    float bLow    = floor(bSlice);
    float bHigh   = min(bLow + 1.0, lutN - 1.0);
    float bFrac   = bSlice - bLow;

    float texW = lutN * lutN;
    float texH = lutN;

    float2 uvLow  = float2((bLow  * lutN + lutCoord.r * (lutN - 1.0) + 0.5) / texW,
                           (lutCoord.g * (lutN - 1.0) + 0.5) / texH);
    float2 uvHigh = float2((bHigh * lutN + lutCoord.r * (lutN - 1.0) + 0.5) / texW,
                           (lutCoord.g * (lutN - 1.0) + 0.5) / texH);

    float3 colLow  = lut.sample(s, uvLow).rgb;
    float3 colHigh = lut.sample(s, uvHigh).rgb;
    return mix(colLow, colHigh, bFrac);
}

/// FXN-R Tone Curve
/// 映射表（来自提交参数）：阴影压、中间调通透、高光 rolloff
/// 使用 9 个控制点的分段线性插値
float applyFxnrToneCurve(float x) {
    // FXN-R Tone Curve 控制点（输入 0-1 对应输出 0-1）
    // Input:  0     16    32    64    96    128   160   192   224   255
    // Output: 0     10    24    57    92    124   168   210   238   250
    const float inputs[10]  = {0.0, 0.0627, 0.1255, 0.2510, 0.3765, 0.5020, 0.6275, 0.7529, 0.8784, 1.0};
    const float outputs[10] = {0.0, 0.0392, 0.0941, 0.2235, 0.3608, 0.4863, 0.6588, 0.8235, 0.9333, 0.9804};
    // 分段线性插値
    for (int i = 0; i < 9; i++) {
        if (x <= inputs[i + 1]) {
            float t = (x - inputs[i]) / (inputs[i + 1] - inputs[i]);
            return mix(outputs[i], outputs[i + 1], t);
        }
    }
    return outputs[9];
}

/// 高光柔和滚落（Highlight Rolloff）
/// 对高亮区域施加柔和压制，防止过曝层次失真
float3 applyHighlightRolloff(float3 color, float rolloff) {
    if (rolloff <= 0.0) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    // 高光区域：亮度 > (1 - rolloff)
    float threshold = 1.0 - rolloff;
    float highlight = clamp((luma - threshold) / rolloff, 0.0, 1.0);
    // 在高光区域施加 S 形压制，保留色彩层次
    float compress = 1.0 - highlight * highlight * 0.3;
    return clamp(color * compress, 0.0, 1.0);
}

// MARK: - Tint 偏移（绿-品轴）
/// 正值 = 偏绿（+G -M），负值 = 偏品（-G +M）
float3 applyTintShift(float3 color, float shift) {
    float s = shift / 1000.0;
    color.g = clamp(color.g + s * 0.2, 0.0, 1.0);
    return color;
}

// MARK: - ColorBias （RGB 通道偏移）
float3 applyColorBias(float3 color, float biasR, float biasG, float biasB) {
    color.r = clamp(color.r + biasR, 0.0, 1.0);
    color.g = clamp(color.g + biasG, 0.0, 1.0);
    color.b = clamp(color.b + biasB, 0.0, 1.0);
    return color;
}
float3 applyDeviceCalibration(
    float3 color,
    float gammaVal,
    float3 whiteScale,
    float3 ccmRow0,
    float3 ccmRow1,
    float3 ccmRow2
) {
    color = clamp(color * whiteScale, 0.0, 1.0);
    color = clamp(float3(
        dot(ccmRow0, color),
        dot(ccmRow1, color),
        dot(ccmRow2, color)
    ), 0.0, 1.0);
    if (fabs(gammaVal - 1.0) > 0.0001) {
        float invGamma = 1.0 / max(gammaVal, 0.001);
        color = pow(clamp(color, 0.0, 1.0), float3(invGamma));
    }
    return clamp(color, 0.0, 1.0);
}

// MARK: - Lightroom 风格参数
float3 applyHighlightsShadows(float3 color, float highlights, float shadows, float whites, float blacks) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    // Highlights: 影响亮部（luma > 0.5）
    float hiMask = clamp((luma - 0.5) * 2.0, 0.0, 1.0);
    color += hiMask * highlights * 0.01;
    // Shadows: 影响暗部（luma < 0.5）
    float shMask = clamp((0.5 - luma) * 2.0, 0.0, 1.0);
    color += shMask * shadows * 0.01;
    // Whites: 影响极亮部（luma > 0.75）
    float whMask = clamp((luma - 0.75) * 4.0, 0.0, 1.0);
    color += whMask * whites * 0.01;
    // Blacks: 影响极暗部（luma < 0.25）
    float blMask = clamp((0.25 - luma) * 4.0, 0.0, 1.0);
    color += blMask * blacks * 0.01;
    return clamp(color, 0.0, 1.0);
}

float3 applyClarity(float3 color, texture2d<float> tex, sampler s, float2 uv, float2 texelSize, float clarity) {
    if (clarity == 0.0) return color;
    // 简化版清晰度：局部对比度增强
    float3 blurred =
        tex.sample(s, uv + float2(-texelSize.x * 2.0, 0.0)).rgb * 0.25 +
        tex.sample(s, uv + float2( texelSize.x * 2.0, 0.0)).rgb * 0.25 +
        tex.sample(s, uv + float2(0.0, -texelSize.y * 2.0)).rgb * 0.25 +
        tex.sample(s, uv + float2(0.0,  texelSize.y * 2.0)).rgb * 0.25;
    float3 detail = color - blurred;
    return clamp(color + detail * clarity * 0.5, 0.0, 1.0);
}

float3 applyVibrance(float3 color, float vibrance) {
    if (vibrance == 0.0) return color;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float maxC = max(max(color.r, color.g), color.b);
    float minC = min(min(color.r, color.g), color.b);
    float sat = (maxC > 0.0) ? (maxC - minC) / maxC : 0.0;
    // 低饱和区域增强更多
    float boost = (1.0 - sat) * vibrance * 0.02;
    return clamp(mix(float3(luma), color, 1.0 + boost), 0.0, 1.0);
}

// MARK: - Paper Texture （相纸纹理）
float3 applyPaperTexture(float3 color, float2 uv, float amount, float time) {
    if (amount <= 0.0) return color;
    float paper = random(uv * 8.0, time * 0.001 + 42.0);
    return clamp(color + (paper - 0.5) * amount * 0.15, 0.0, 1.0);
}

// MARK: - Chemical Irregularity （化学不规则感）
float3 applyChemicalIrregularity(float3 color, float2 uv, float amount, float time) {
    if (amount <= 0.0) return color;
    float irr = random(uv * 3.0, time * 0.002 + 17.0) - 0.5;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float midMask = 1.0 - abs(luma - 0.5) * 2.0;
    return clamp(color + irr * amount * midMask * 0.2, 0.0, 1.0);
}

// MARK: - CCD 风格片段着色器
fragment float4 ccdFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> lutTexture [[texture(1)]],
    texture2d<float> grainTexture [[texture(2)]],
    constant CCDParams &params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = in.texCoord;

    // 鱼眼模式：重映射 UV 坐标
    bool isFisheye = params.fisheyeMode > 0.5;
    bool useCircularFisheye = params.circularFisheye > 0.5;
    if (isFisheye) {
        if (useCircularFisheye) {
            float2 fUV = fisheyeUV(uv, params.aspectRatio);
            if (fUV.x < 0.0) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }
            uv = fUV;
        } else {
            uv = fisheyeRectUV(uv, params.aspectRatio);
        }
    } else if (fabs(params.lensDistortion) > 0.0001) {
        uv = clamp(barrelDistortUV(uv, params.lensDistortion, params.aspectRatio), float2(0.0), float2(1.0));
    }

    // 计算单像素大小（用于锐化卷积）
    uint texWidth  = cameraTexture.get_width();
    uint texHeight = cameraTexture.get_height();
    float2 texelSize = float2(1.0 / float(texWidth), 1.0 / float(texHeight));

    // === Pass 0: 锐化 (Unsharp Mask) ===
    // 在色彩调整之前对原始相机纹理做锐化，保留更多细节
    float3 color;
    if (params.sharpen > 0.0) {
        color = applySharpen(cameraTexture, textureSampler, uv, texelSize, params.sharpen);
    } else {
        color = cameraTexture.sample(textureSampler, uv).rgb;
    }

    // === Pass 1: 色差 (Chromatic Aberration) ===
    // 对 R、G、B 三个通道分别采样略微偏移的位置，模拟镜头色差
    if (params.chromaticAberration > 0.0) {
        float ca = params.chromaticAberration;
        float r = cameraTexture.sample(textureSampler, uv + float2(ca, 0.0)).r;
        float g = cameraTexture.sample(textureSampler, uv).g;
        float b = cameraTexture.sample(textureSampler, uv - float2(ca, 0.0)).b;
        color = float3(r, g, b);
    }

    // === Pass 1.5: 曝光补偿（在色温之前应用，模拟相机 EV 补偿） ===
    if (params.exposureOffset != 0.0) {
        color *= pow(2.0, params.exposureOffset);
        color = clamp(color, 0.0, 1.0);
    }

    // === Pass 1.75: 设备级色彩校准（白点缩放 + CCM + Gamma） ===
    color = applyDeviceCalibration(
        color,
        params.deviceGamma,
        float3(params.deviceWhiteScaleR, params.deviceWhiteScaleG, params.deviceWhiteScaleB),
        float3(params.deviceCcm00, params.deviceCcm01, params.deviceCcm02),
        float3(params.deviceCcm10, params.deviceCcm11, params.deviceCcm12),
        float3(params.deviceCcm20, params.deviceCcm21, params.deviceCcm22)
    );

    // === Pass 2: 基础色彩调整 ===
    color = applyTemperatureShift(color, params.temperatureShift);
    color = applyTintShift(color, params.tintShift);
    color = applyColorBias(color, params.colorBiasR, params.colorBiasG, params.colorBiasB);
    color = applyContrast(color, params.contrast);
    color = applySaturation(color, params.saturation);
    
    // === Pass 2.1: Lightroom 风格参数 ===
    color = applyHighlightsShadows(color, params.highlights, params.shadows, params.whites, params.blacks);
    color = applyClarity(color, cameraTexture, textureSampler, uv, texelSize, params.clarity);
    color = applyVibrance(color, params.vibrance);
    
    // === Pass 2.5: 高光柔和滚落 (Highlight Rolloff) ===
    // FXN-R=0.16：高光层次保留，防止过曝失真
    if (params.highlightRolloff > 0.0) {
        color = applyHighlightRolloff(color, params.highlightRolloff);
    }

    // === Pass 3: 高光溢出 (Bloom / Halation) ===
    // 简化版：对亮度超过阈値的区域增加光晕
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (luminance > 0.8 && params.bloomAmount > 0.0) {
        float bloom = (luminance - 0.8) * params.bloomAmount * 2.0;
        color = clamp(color + float3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }
    
    // === Pass 4: 胶片颗粒 (Grain) ===
    // 从预烘焙的噪点纹理中采样并叠加
    // grain 采样（预留用于未来胶片效果）
    float3 grain = grainTexture.sample(textureSampler, uv * 2.0).rgb;
    (void)grain; // 防止未使用警告
    
    // === Pass 5: 动态数字噪点 (Noise) ===
    // 模拟 CCD 传感器的暗部噪点，使用时间种子使其动态变化
    if (params.noiseAmount > 0.0) {
        float noise = random(uv, params.time) - 0.5;
        float darkMask = 1.0 - luminance;
        color = clamp(color + noise * params.noiseAmount * 0.2 * darkMask, 0.0, 1.0);
    }
    // 亮度噪声（FXN-R=0.02）
    if (params.luminanceNoise > 0.0) {
        float ln = random(uv, params.time + 1.7) - 0.5;
        color = clamp(color + ln * params.luminanceNoise * 0.15, 0.0, 1.0);
    }
    // 色度噪声（FXN-R=0.01，极低）
    if (params.chromaNoise > 0.0) {
        float cr = random(uv, params.time + 3.1) - 0.5;
        float cg = random(uv, params.time + 5.3) - 0.5;
        float cb = random(uv, params.time + 7.7) - 0.5;
        color = clamp(color + float3(cr, cg, cb) * params.chromaNoise * 0.08, 0.0, 1.0);
    }

    // === Pass 6: 传感器非均匀性 + 肤色保护 ===
    // 中心增亮 + 边缘衰减（FXN-R: centerGain=0.010, edgeFalloff=0.035）
    if (params.centerGain > 0.0 || params.edgeFalloff > 0.0) {
        float factor = ccdCenterEdge(uv, params.centerGain, params.edgeFalloff);
        color = clamp(color * factor, 0.0, 1.0);
    }
    // 曝光波动（FXN-R=0.020，数码传感器轻微不均匀）
    if (params.exposureVariation > 0.0) {
        float evn = random(uv * 0.1, params.time * 0.01) - 0.5;
        color = clamp(color + evn * params.exposureVariation * 0.3, 0.0, 1.0);
    }
    // 角落色温偏移（FXN-R=-0.015，负値=偏冷青）
    if (params.cornerWarmShift != 0.0) {
        color = ccdCornerWarm(uv, color, params.cornerWarmShift);
    }
    // 显影柔化（FXN-R=0.020，比 instant 更锐）
    if (params.developmentSoftness > 0.0) {
        color = ccdDevelopmentSoften(cameraTexture, textureSampler, uv, texelSize, color, params.developmentSoftness);
    }
    // 肤色保护（FXN-R: skinHueProtect=1.0, skinSatProtect=0.96, skinLumaSoften=0.03, skinRedLimit=1.04）
    color = ccdSkinProtect(color, params.skinHueProtect, params.skinSatProtect, params.skinLumaSoften, params.skinRedLimit);

    // === Pass 7: 3D LUT 采样 ===
    // FXN-R 的冷青色调核心，通过 LUT 实现 Fuji Film Simulation
    // lutEnabled=1.0 时启用，lutStrength 控制混合比例
    if (params.lutEnabled > 0.5) {
        float n = params.lutSize > 0.0 ? params.lutSize : 33.0;
        float3 lutColor = sampleLUT(lutTexture, textureSampler, color, n);
        color = mix(color, lutColor, clamp(params.lutStrength, 0.0, 1.0));
    }

    // === Pass 8: Tone Curve ===
    // FXN-R Tone Curve：阴影压、中间调通透、高光滚落
    // toneCurveStrength=1.0 全量应用，0.0 跳过
    if (params.toneCurveStrength > 0.0) {
        float3 curved;
        curved.r = applyFxnrToneCurve(color.r);
        curved.g = applyFxnrToneCurve(color.g);
        curved.b = applyFxnrToneCurve(color.b);
        color = mix(color, curved, params.toneCurveStrength);
    }

    // === Pass 8.5: Paper Texture + Chemical Irregularity ===
    color = applyPaperTexture(color, uv, params.paperTexture, params.time);
    color = applyChemicalIrregularity(color, uv, params.chemicalIrregularity, params.time);

    // === Pass 9: 暗角 (Vignette) ===
    // 鱼眼模式下不叠加额外暗角，圆形边缘已有自然渐暗
    if (!isFisheye || !useCircularFisheye) {
        float vignette = vignetteEffect(uv, params.vignetteAmount);
        color *= vignette;
    }
    
    return float4(color, 1.0);
}
