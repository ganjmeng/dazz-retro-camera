#pragma version(1)
#pragma rs java_package_name(com.retrocam.app)
#pragma rs_fp_relaxed

// 包含所有相机参数的结构体
// public static class CaptureParams {...} in Java

// RenderScript 内核函数
uchar4 RS_KERNEL capturePipeline(uchar4 in, uint32_t x, uint32_t y) {
  float4 color = rsUnpackColor8888(in);

  // 在这里实现所有像素级处理
  // ...

  // 示例：简单的亮度调整
  color.rgb *= 0.95f;

  return rsPackColorTo8888(color);
}
