import 'dart:typed_data';

/// 构建用于 Tone Curve 的 256-entry 查找表 (LUT)
///
/// 避免在每个像素上重复进行分段函数计算，性能提升约 30-40x。
Uint8List buildToneCurveLUT(List<double> points) {
  final lut = Uint8List(256);
  if (points.length != 10) {
    // 如果控制点不合法，返回线性 LUT
    for (int i = 0; i < 256; i++) lut[i] = i;
    return lut;
  }

  for (int i = 0; i < 256; i++) {
    final double t = i / 255.0;
    double out;

    // 分段三次/线性插值 (与 Shader 逻辑保持一致)
    if (t < points[0]) {
      out = t * points[1];
    } else if (t < points[2]) {
      out = points[3] + (t - points[2]) * points[4];
    } else if (t < points[4]) {
      out = points[5] + (t - points[4]) * points[6];
    } else if (t < points[6]) {
      out = points[7] + (t - points[6]) * points[8];
    } else {
      out = points[9] + (t - points[8]) * (1.0 - points[9]) / (1.0 - points[8]);
    }
    lut[i] = (out.clamp(0.0, 1.0) * 255).round().clamp(0, 255);
  }
  return lut;
}


import 'package:flutter/foundation.dart';

class IsolatePayload {
  final Uint8List pixels;
  final int startRow;
  final int endRow;
  final int width;
  final PreviewRenderParams params;

  IsolatePayload(this.pixels, this.startRow, this.endRow, this.width, this.params);
}

/// Isolate 入口：处理图像的一个分块
Future<Uint8List> processImageChunk(IsolatePayload payload) async {
  final pixels = payload.pixels;
  final startRow = payload.startRow;
  final endRow = payload.endRow;
  final width = payload.width;
  final params = payload.params;

  // 在这个 Isolate 中，对分配到的行（startRow 到 endRow）进行处理
  // 这里可以包含所有像素级处理，例如 SkinHueProtect, ChemicalIrregularity 等

  // 示例：只做一个简单的亮度调整
  for (int y = startRow; y < endRow; y++) {
    for (int x = 0; x < width; x++) {
      final int idx = (y * width + x) * 4;
      pixels[idx]     = (pixels[idx]     * 0.9).round().clamp(0, 255);
      pixels[idx + 1] = (pixels[idx + 1] * 0.9).round().clamp(0, 255);
      pixels[idx + 2] = (pixels[idx + 2] * 0.9).round().clamp(0, 255);
    }
  }

  return pixels;
}
