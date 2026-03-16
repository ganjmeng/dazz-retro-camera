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
    float contrast;
    float saturation;
    float temperatureShift;  // 色温偏移，负数偏冷
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
    float time;              // 用于动态噪点的时间种子
    float fisheyeMode;       // 1.0=圆形鱼眼模式, 0.0=普通模式
    float aspectRatio;       // 宽/高 比例（用于保持圆形）
    // ── 传感器非均匀性（数码相机通用，FXN-R 专项调校）────────────────────
    float centerGain;        // 中心增亮（FXN-R=0.010，极轻）
    float edgeFalloff;       // 边缘衰减（FXN-R=0.035，镜头暗角）
    float exposureVariation; // 曝光波动（FXN-R=0.020，数码更稳定）
    float cornerWarmShift;   // 角落色温偏移（FXN-R=-0.015，负=偏冷青）
    float developmentSoftness; // 显影柔化（FXN-R=0.020）
    float chemicalIrregularity; // 化学不规则感（FXN-R=0.010，极低）
    // ── 肤色保护（冷色调相机必须开启，防止肤色发青）────────────────────
    float skinHueProtect;    // 肤色色相保护（1.0=开启，0.0=关闭）
    float skinSatProtect;    // 肤色饱和度保护（FXN-R=0.96）
    float skinLumaSoften;    // 肤色亮度柔化（FXN-R=0.030）
    float skinRedLimit;      // 肤色红限（FXN-R=1.04，防止冷 LUT 削红）
    // ── 噪声分离（亮度/色度）────────────────────────────────────────────
    float luminanceNoise;    // 亮度噪声（FXN-R=0.02）
    float chromaNoise;       // 色度噪声（FXN-R=0.01）
};

// MARK: - 工具函数

/// 计算暗角强度
float vignetteEffect(float2 uv, float amount) {
    float2 d = uv - 0.5;
    return 1.0 - dot(d, d) * amount * 2.5;
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
    if (r > 1.0) return float2(-1.0); // 圆外标记
    // 等距投影：theta = r * (π/2)
    float theta = r * 1.5707963; // M_PI_F / 2
    float phi = atan2(p.y, p.x);
    float sinTheta = sin(theta);
    float2 texCoord = float2(
        sinTheta * cos(phi),
        sinTheta * sin(phi)
    );
    return texCoord * 0.5 + 0.5;
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
    if (params.fisheyeMode > 0.5) {
        float2 fUV = fisheyeUV(uv, params.aspectRatio);
        if (fUV.x < 0.0) {
            // 圆形以外：输出纯黑
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        uv = fUV;
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

    // === Pass 2: 基础色彩调整 ===
    color = applyTemperatureShift(color, params.temperatureShift);
    color = applyContrast(color, params.contrast);
    color = applySaturation(color, params.saturation);
    
    // === Pass 3: 高光溢出 (Bloom / Halation) ===
    // 简化版：对亮度超过阈值的区域增加光晕
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    if (luminance > 0.8 && params.bloomAmount > 0.0) {
        float bloom = (luminance - 0.8) * params.bloomAmount * 2.0;
        color = clamp(color + float3(bloom * 0.8, bloom * 0.7, bloom * 0.5), 0.0, 1.0);
    }
    
    // === Pass 4: 胶片颗粒 (Grain) ===
    // 从预烘焙的噪点纹理中采样并叠加
    if (params.grainAmount > 0.0) {
        float3 grain = grainTexture.sample(textureSampler, uv * 2.0).rgb;
        color = clamp(color + (grain - 0.5) * params.grainAmount * 0.3, 0.0, 1.0);
    }
    
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

    // === Pass 7: 暗角 (Vignette) ===
    // 鱼眼模式下不叠加额外暗角，圆形边缘已有自然渐暗
    if (params.fisheyeMode < 0.5) {
        float vignette = vignetteEffect(uv, params.vignetteAmount);
        color *= vignette;
    }
    
    return float4(color, 1.0);
}
