import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../preview_renderer.dart';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// LUT 预计算工具函数
// ─────────────────────────────────────────────────────────────────────────────

/// 构建 Tone Curve 的 256-entry 查找表
/// 算法与 InstCShader.metal 中的 instcToneCurve() 完全一致（5 段三次平滑插值）
Uint8List buildToneCurveLUT() {
  final lut = Uint8List(256);
  for (int i = 0; i < 256; i++) {
    final double x = i / 255.0;
    double out;
    if (x < 0.125) {
      final double t = x / 0.125;
      final double t2 = t * t;
      final double t3 = t2 * t;
      out = 0.024 + (0.133 - 0.024) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.251) {
      final double t = (x - 0.125) / 0.126;
      final double t2 = t * t;
      final double t3 = t2 * t;
      out = 0.133 + (0.267 - 0.133) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.502) {
      final double t = (x - 0.251) / 0.251;
      final double t2 = t * t;
      final double t3 = t2 * t;
      out = 0.267 + (0.510 - 0.267) * (3.0 * t2 - 2.0 * t3);
    } else if (x < 0.753) {
      final double t = (x - 0.502) / 0.251;
      final double t2 = t * t;
      final double t3 = t2 * t;
      out = 0.510 + (0.792 - 0.510) * (3.0 * t2 - 2.0 * t3);
    } else {
      final double t = (x - 0.753) / 0.247;
      final double t2 = t * t;
      final double t3 = t2 * t;
      out = 0.792 + (0.973 - 0.792) * (3.0 * t2 - 2.0 * t3);
    }
    lut[i] = (out.clamp(0.0, 1.0) * 255).round().clamp(0, 255);
  }
  return lut;
}

/// 构建 Highlight Rolloff 的 256-entry 查找表
/// 返回每个亮度值对应的 rolloff 强度（0.0~1.0）
/// 算法与 InstCShader.metal 中的 instcHighlightRolloff() 完全一致
Float32List buildHighlightRolloffLUT(double rolloff) {
  final lut = Float32List(256);
  if (rolloff < 0.001) return lut; // 全零，不做任何处理
  for (int i = 0; i < 256; i++) {
    final double lum = i / 255.0;
    if (lum > 0.70) {
      double mask = ((lum - 0.70) / 0.30).clamp(0.0, 1.0);
      mask = mask * mask * (3.0 - 2.0 * mask); // smoothstep
      lut[i] = mask * rolloff;
    }
  }
  return lut;
}

/// 构建传感器非均匀性权重表（每像素 3 个 float：R/G/B 增益）
/// 算法与 InstCShader.metal 中的 instcCenterGain() + instcEdgeFalloff() 完全一致
Float32List buildSensorNonUniformityTable(
    int width, int height, double centerGain, double edgeFalloff,
    {double cornerWarmShift = 0.0}) {
  final table = Float32List(width * height * 3);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int idx = (y * width + x) * 3;
      final double u = x / (width - 1.0);
      final double v = y / (height - 1.0);
      final double cx = u - 0.5;
      final double cy = v - 0.5;

      // Center Gain（中心增亮，偏暖白，模拟内置闪光灯）
      final double dist = math.sqrt(cx * cx * 1.0 + cy * cy * 1.21); // 轻微椭圆
      double centerMask = (1.0 - _smoothstep(0.0, 0.45, dist)).clamp(0.0, 1.0);
      centerMask = centerMask * centerMask;
      final double gainR = 1.0 + centerMask * centerGain * 1.2;
      final double gainG = 1.0 + centerMask * centerGain * 1.0;
      final double gainB = 1.0 + centerMask * centerGain * 0.7;

      // Edge Falloff（边缘曝光衰减）
      final double edgeDist = cx * cx * 1.44 + cy * cy; // 椭圆
      double falloff = 1.0 - _smoothstep(0.10, 0.35, edgeDist);
      falloff = falloff.clamp(0.6, 1.0);
      final double edgeMult = edgeFalloff < 0.001 ? 1.0 : (1.0 - edgeFalloff * (1.0 - falloff));

      // Corner Warm Shift（边角偏暖，FXN-R 专属）
      double warmR = 0.0, warmB = 0.0;
      if (cornerWarmShift.abs() > 0.001) {
        final double cornerDist = math.sqrt(cx * cx + cy * cy);
        final double cornerMask = _smoothstep(0.25, 0.55, cornerDist);
        warmR = cornerMask * cornerWarmShift.abs() * 0.08;
        warmB = -cornerMask * cornerWarmShift.abs() * 0.06;
      }

      table[idx]     = (gainR * edgeMult + warmR).clamp(0.0, 2.0);
      table[idx + 1] = (gainG * edgeMult).clamp(0.0, 2.0);
      table[idx + 2] = (gainB * edgeMult + warmB).clamp(0.0, 2.0);
    }
  }
  return table;
}

double _smoothstep(double edge0, double edge1, double x) {
  final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// ─────────────────────────────────────────────────────────────────────────────
// Isolate 并行处理
// ─────────────────────────────────────────────────────────────────────────────

class IsolatePayload {
  final Uint8List pixels;
  final int startRow;
  final int endRow;
  final int width;
  final int height;
  final double skinSatProtect;
  final double skinLumaSoften;
  final double skinRedLimit;
  final bool skinHueProtect;
  final double chemicalIrregularity;
  final double paperTexture;
  final double developmentSoftness;

  const IsolatePayload({
    required this.pixels,
    required this.startRow,
    required this.endRow,
    required this.width,
    required this.height,
    required this.skinSatProtect,
    required this.skinLumaSoften,
    required this.skinRedLimit,
    required this.skinHueProtect,
    required this.chemicalIrregularity,
    required this.paperTexture,
    required this.developmentSoftness,
  });

  factory IsolatePayload.fromParams(
      Uint8List pixels, int startRow, int endRow, int width, int height,
      PreviewRenderParams params) {
    return IsolatePayload(
      pixels: pixels,
      startRow: startRow,
      endRow: endRow,
      width: width,
      height: height,
      skinSatProtect: params.defaultLook.skinSatProtect,
      skinLumaSoften: params.defaultLook.skinLumaSoften,
      skinRedLimit: params.defaultLook.skinRedLimit,
      skinHueProtect: params.skinHueProtect,
      chemicalIrregularity: params.chemicalIrregularity,
      paperTexture: params.paperTexture,
      developmentSoftness: params.developmentSoftness,
    );
  }
}

/// Isolate 入口：对图像分块进行像素级处理
/// 完整移植自 InstCShader.metal 中的以下函数：
///   - instcSkinProtect()
///   - instcChemicalIrregularity()
///   - instcPaperTexture()
Uint8List processImageChunk(IsolatePayload payload) {
  // 注意：Isolate 中不能使用 async/await，必须是同步函数
  final pixels = Uint8List.fromList(payload.pixels); // 复制，避免跨 Isolate 共享内存问题
  final startRow = payload.startRow;
  final endRow = payload.endRow;
  final width = payload.width;

  // 伪随机数生成器（与 Metal Shader 的 instcRandom() 对齐）
  // Metal: fract(sin(dot(uv + seed, float2(127.1, 311.7))) * 43758.5453123)
  double _random(double ux, double uy, double seed) {
    final double dot = (ux + seed) * 127.1 + (uy + seed) * 311.7;
    return (math.sin(dot) * 43758.5453123) % 1.0;
  }

  for (int y = startRow; y < endRow; y++) {
    for (int x = 0; x < width; x++) {
      final int idx = (y * width + x) * 4;
      double r = pixels[idx] / 255.0;
      double g = pixels[idx + 1] / 255.0;
      double b = pixels[idx + 2] / 255.0;

      // ── 1. 肤色保护（完整移植自 instcSkinProtect()）──────────────────────
      if (payload.skinHueProtect) {
        final double maxC = math.max(math.max(r, g), b);
        final double minC = math.min(math.min(r, g), b);
        final double delta = maxC - minC;
        final double lum = (maxC + minC) * 0.5;
        final double sat = (delta < 0.001)
            ? 0.0
            : delta / (1.0 - (2.0 * lum - 1.0).abs());

        double hue = 0.0;
        if (delta > 0.001) {
          if (maxC == r) {
            hue = ((g - b) / delta) % 6.0;
          } else if (maxC == g) {
            hue = (b - r) / delta + 2.0;
          } else {
            hue = (r - g) / delta + 4.0;
          }
          hue = hue / 6.0;
          if (hue < 0.0) hue += 1.0;
        }

        // 肤色检测：Hue 0~50°（0.0~0.139），Sat 0.15~0.85，Lum 0.2~0.85
        final bool isSkin = (hue >= 0.0 && hue <= 0.139) &&
            (sat >= 0.15 && sat <= 0.85) &&
            (lum >= 0.20 && lum <= 0.85);

        if (isSkin) {
          final double hueMask =
              1.0 - _smoothstep(0.10, 0.139, hue);
          final double satMask = _smoothstep(0.15, 0.25, sat) *
              (1.0 - _smoothstep(0.75, 0.85, sat));
          final double lumMask = _smoothstep(0.20, 0.35, lum) *
              (1.0 - _smoothstep(0.75, 0.85, lum));
          final double skinMask = hueMask * satMask * lumMask;

          // 1a. 饱和度保护：防止肤色过饱和变橙
          final double lumVal = 0.2126 * r + 0.7152 * g + 0.0722 * b;
          final double desatR = lumVal + (r - lumVal) * payload.skinSatProtect;
          final double desatG = lumVal + (g - lumVal) * payload.skinSatProtect;
          final double desatB = lumVal + (b - lumVal) * payload.skinSatProtect;
          r = r + (desatR - r) * skinMask * 0.6;
          g = g + (desatG - g) * skinMask * 0.6;
          b = b + (desatB - b) * skinMask * 0.6;

          // 1b. 亮度柔化：Instax Mini 肤色有轻微发光感
          final double lumBoost = lum * payload.skinLumaSoften * 0.8;
          r = (r + lumBoost).clamp(0.0, 1.0);
          g = (g + lumBoost).clamp(0.0, 1.0);
          b = (b + lumBoost).clamp(0.0, 1.0);

          // 1c. 红限：防止肤色过红
          r = r.clamp(0.0, payload.skinRedLimit);
        }
      }

      // ── 2. 化学不规则感（完整移植自 instcChemicalIrregularity()）────────
      if (payload.chemicalIrregularity > 0.001) {
        final double ux = x / width.toDouble();
        final double uy = y / payload.height.toDouble();
        // 低频噪声（UV 缩放 2.5x，模拟空间相关性）
        final double irregUX = ux * 2.5;
        final double irregUY = uy * 2.5;
        final double irreg1 = _random(irregUX, irregUY, 0.0) * 2.0 - 1.0;
        final double irreg2 =
            _random(irregUX * 1.7 + 0.3, irregUY * 1.7 + 0.3, 0.2) * 2.0 - 1.0;
        final double irregularity = irreg1 * 0.6 + irreg2 * 0.4;
        final double brightVar =
            irregularity * payload.chemicalIrregularity * 0.03;
        r = (r + brightVar + irregularity * payload.chemicalIrregularity * 0.008)
            .clamp(0.0, 1.0);
        g = (g + brightVar + irregularity * payload.chemicalIrregularity * 0.004)
            .clamp(0.0, 1.0);
        b = (b + brightVar - irregularity * payload.chemicalIrregularity * 0.006)
            .clamp(0.0, 1.0);
      }

      // ── 3. 相纸纹理（完整移植自 instcPaperTexture()）────────────────────
      if (payload.paperTexture > 0.001) {
        final double ux = x / width.toDouble();
        final double uy = y / payload.height.toDouble();
        // 双频纹理（8x 低频 + 32x 高频）
        final double paper1 = _random(ux * 8.0, uy * 8.0, 0.0) * 2.0 - 1.0;
        final double paper2 = _random(ux * 32.0, uy * 32.0, 1.0) * 2.0 - 1.0;
        final double paper = paper1 * 0.7 + paper2 * 0.3;
        final double paperOffset = paper * payload.paperTexture * 0.04;
        r = (r + paperOffset).clamp(0.0, 1.0);
        g = (g + paperOffset).clamp(0.0, 1.0);
        b = (b + paperOffset).clamp(0.0, 1.0);
      }

      pixels[idx] = (r * 255).round().clamp(0, 255);
      pixels[idx + 1] = (g * 255).round().clamp(0, 255);
      pixels[idx + 2] = (b * 255).round().clamp(0, 255);
    }
  }

  return pixels;
}

double _smoothstep(double edge0, double edge1, double x) {
  final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}
