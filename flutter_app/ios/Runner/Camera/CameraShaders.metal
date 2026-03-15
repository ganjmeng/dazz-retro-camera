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
    float time;        // 用于动态噪点的时间种子
    float fisheyeMode; // 1.0=圆形鱼眼模式, 0.0=普通模式
    float aspectRatio; // 宽/高 比例（用于保持圆形）
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
float3 applyTemperatureShift(float3 color, float shift) {
    // 负值（冷色）：增强蓝色通道，减弱红色通道
    float normalizedShift = shift / 1000.0;
    color.r = clamp(color.r - normalizedShift * 0.3, 0.0, 1.0);
    color.b = clamp(color.b + normalizedShift * 0.3, 0.0, 1.0);
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
        // 暗部区域噪点更明显
        float darkMask = 1.0 - luminance;
        color = clamp(color + noise * params.noiseAmount * 0.2 * darkMask, 0.0, 1.0);
    }
    
    // === Pass 6: 暗角 (Vignette) ===
    // 鱼眼模式下不叠加额外暗角，圆形边缘已有自然渐暗
    if (params.fisheyeMode < 0.5) {
        float vignette = vignetteEffect(uv, params.vignetteAmount);
        color *= vignette;
    }
    
    return float4(color, 1.0);
}
