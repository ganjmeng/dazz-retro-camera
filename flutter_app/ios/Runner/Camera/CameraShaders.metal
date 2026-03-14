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
    float time; // 用于动态噪点的时间种子
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

// MARK: - CCD 风格片段着色器

fragment float4 ccdFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> lutTexture [[texture(1)]],
    texture2d<float> grainTexture [[texture(2)]],
    constant CCDParams &params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    float2 uv = in.texCoord;
    
    // === Pass 1: 色差 (Chromatic Aberration) ===
    // 对 R、G、B 三个通道分别采样略微偏移的位置，模拟镜头色差
    float ca = params.chromaticAberration;
    float r = cameraTexture.sample(textureSampler, uv + float2(ca, 0.0)).r;
    float g = cameraTexture.sample(textureSampler, uv).g;
    float b = cameraTexture.sample(textureSampler, uv - float2(ca, 0.0)).b;
    float3 color = float3(r, g, b);
    
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
    float vignette = vignetteEffect(uv, params.vignetteAmount);
    color *= vignette;
    
    return float4(color, 1.0);
}
