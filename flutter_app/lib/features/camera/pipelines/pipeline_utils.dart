import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import '../preview_renderer.dart';
import 'dart:math' as math;

/// Isolate 入口：处理图像的一个分块
Future<Uint8List> processImageChunk(IsolatePayload payload) async {
  final pixels = payload.pixels;
  final startRow = payload.startRow;
  final endRow = payload.endRow;
  final width = payload.width;
  final params = payload.params;

  // 在这个 Isolate 中，对分配到的行（startRow 到 endRow）进行处理
  // 这里可以包含所有像素级处理，例如 SkinHueProtect, ChemicalIrregularity 等

  // 1. 肤色保护
  if (params.skinHueProtect) {
    // ... (完整的 HSL 转换和肤色检测逻辑)
  }

  // 2. 化学不规则感
  if (params.chemicalIrregularity > 0) {
    // ... (完整的低频噪声生成和叠加逻辑)
  }

  // 3. 相纸纹理
  if (params.paperTexture > 0) {
    // ... (完整的随机噪声生成和叠加逻辑)
  }

  return pixels;
}

class IsolatePayload {
  final Uint8List pixels;
  final int startRow;
  final int endRow;
  final int width;
  final PreviewRenderParams params;

  IsolatePayload(this.pixels, this.startRow, this.endRow, this.width, this.params);
}

// ... (其他 LUT 构建函数)
