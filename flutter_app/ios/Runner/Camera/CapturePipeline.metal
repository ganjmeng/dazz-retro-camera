#include <metal_stdlib>
using namespace metal;

// ── 包含所有相机专属 Shader 的工具函数 ───────────────────────────────────
#include "CameraShaders.metal"
#include "InstCShader.metal"
#include "SQCShader.metal"
// ... (include all other shader files)

struct CaptureParams {
  // 这里包含所有相机需要的参数
  // e.g., float highlightRolloff;
  // e.g., int cameraId;
};

kernel void capturePipeline(
  texture2d<float, access::read>  inTexture  [[texture(0)]],
  texture2d<float, access::write> outTexture [[texture(1)]],
  constant CaptureParams& params [[buffer(0)]],
  uint2 gid [[thread_position_in_grid]])
{
  if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
    return;
  }

  float4 color = inTexture.read(gid);

  // ── 根据 cameraId 调用不同的管线 ───────────────────────────────────────
  // if (params.cameraId == 1) { // InstC
  //   color = processInstC_metal(color, params...);
  // } else if (params.cameraId == 2) { // SQC
  //   color = processSQC_metal(color, params...);
  // } else { // Default CCD
  //   color = processCCD_metal(color, params...);
  // }

  // 示例：只做一个简单的亮度调整
  color.rgb *= 0.95;

  outTexture.write(color, gid);
}
