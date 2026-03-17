import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:retro_cam/features/camera/preview_renderer.dart';

// ── LUT 构建函数 ────────────────────────────────────────────────────────────

// 构建 256-entry 的 Tone Curve LUT
Uint8List buildToneCurveLUT(List<double> curve) {
  final lut = Uint8List(256);
  if (curve.isEmpty) {
    for (int i = 0; i < 256; i++) {
      lut[i] = i;
    }
    return lut;
  }
  final p = curve;
  for (int i = 0; i < 256; i++) {
    final x = i / 255.0;
    double y;
    if (x < p[2]) {
      y = p[0] + p[1] * x;
    } else if (x < p[5]) {
      final tx = x - p[2];
      y = p[3] + p[4] * tx + p[13] * tx * tx;
    } else if (x < p[8]) {
      final tx = x - p[5];
      y = p[6] + p[7] * tx + p[14] * tx * tx;
    } else if (x < p[11]) {
      final tx = x - p[8];
      y = p[9] + p[10] * tx + p[15] * tx * tx;
    } else {
      final tx = x - p[11];
      y = p[12] + p[16] * tx;
    }
    lut[i] = (y.clamp(0.0, 1.0) * 255).round();
  }
  return lut;
}

// 构建 256-entry 的高光滚落 LUT
Float32List buildHighlightRolloffLUT(double rolloff) {
  final lut = Float32List(256);
  for (int i = 0; i < 256; i++) {
    final x = i / 255.0;
    final y = x - (x - 0.70) * rolloff * (x > 0.70 ? 1 : 0);
    lut[i] = y.clamp(0.0, 1.0);
  }
  return lut;
}

// 构建 256x256 的传感器非均匀性 LUT (中心增亮+边缘衰减)
Float32List buildSensorNonUniformityTable(
    int width, int height, double centerGain, double edgeFalloff, double cornerWarmShift) {
  final table = Float32List(width * height * 3); // R, G, B
  final centerX = width / 2.0;
  final centerY = height / 2.0;
  final maxDist = math.sqrt(centerX * centerX + centerY * centerY);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final dx = x - centerX;
      final dy = y - centerY;
      final dist = math.sqrt(dx * dx + dy * dy) / maxDist;

      final gain = 1.0 + (1.0 - _smoothstep(0.0, 0.6, dist)) * centerGain;
      final falloff = 1.0 - _smoothstep(0.3, 1.0, dist) * edgeFalloff;
      final warmShiftR = _smoothstep(0.3, 0.8, dist) * cornerWarmShift * 0.6;
      final warmShiftB = _smoothstep(0.3, 0.8, dist) * cornerWarmShift * 0.4;

      final idx = (y * width + x) * 3;
      table[idx] = gain * falloff + warmShiftR;     // R
      table[idx + 1] = gain * falloff;             // G
      table[idx + 2] = gain * falloff - warmShiftB; // B
    }
  }
  return table;
}

double _smoothstep(double edge0, double edge1, double x) {
  final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// ── Isolate 并行处理 ───────────────────────────────────────────────────────

class IsolatePayload {
  final Uint8List pixels;
  final int startRow;
  final int endRow;
  final int width;
  final int height;
  final IsolateParams params;

  IsolatePayload(this.pixels, this.startRow, this.endRow, this.width, this.height, this.params);
}

class IsolateParams {
  final bool skinHueProtect;
  final double skinSatProtect;
  final double skinLumaSoften;
  final double skinRedLimit;

  final double chemicalIrregularity;
  final double irregUvScale;
  final double irregFreq1;
  final double irregFreq2;
  final double irregWeight1;
  final double irregWeight2;

  final double paperTexture;
  final double paperUvScale1;
  final double paperUvScale2;
  final double paperWeight1;
  final double paperWeight2;

  IsolateParams.from(PreviewRenderParams p) : 
    skinHueProtect = p.skinHueProtect > 0.5,  // FIX: double getter 转 bool
    skinSatProtect = p.skinSatProtect,
    skinLumaSoften = p.skinLumaSoften,
    skinRedLimit = p.skinRedLimit,
    chemicalIrregularity = p.chemicalIrregularity,
    irregUvScale = p.irregUvScale,
    irregFreq1 = p.irregFreq1,
    irregFreq2 = p.irregFreq2,
    irregWeight1 = p.irregWeight1,
    irregWeight2 = p.irregWeight2,
    paperTexture = p.paperTexture,
    paperUvScale1 = p.paperUvScale1,
    paperUvScale2 = p.paperUvScale2,
    paperWeight1 = p.paperWeight1,
    paperWeight2 = p.paperWeight2;
}

// Isolate 入口：处理图像的一个分块
Uint8List processImageChunk(IsolatePayload payload) {
  final pixels = payload.pixels;
  final startRow = payload.startRow;
  final endRow = payload.endRow;
  final width = payload.width;
  final params = payload.params;

  for (int y = startRow; y < endRow; y++) {
    for (int x = 0; x < width; x++) {
      final idx = (y * width + x) * 4;
      double r = pixels[idx] / 255.0;
      double g = pixels[idx + 1] / 255.0;
      double b = pixels[idx + 2] / 255.0;

      // ── 1. 肤色保护 ──────────────────────────────────────────────────
      if (params.skinHueProtect) {
        final double maxC = math.max(math.max(r, g), b);
        final double minC = math.min(math.min(r, g), b);
        final double delta = maxC - minC;
        final double lum = (maxC + minC) * 0.5;
        final double sat = (delta < 0.001) ? 0.0 : delta / (1.0 - (2.0 * lum - 1.0).abs());
        double hue = 0.0;
        if (delta > 0.001) {
          if (maxC == r) hue = ((g - b) / delta) % 6.0;
          else if (maxC == g) hue = (b - r) / delta + 2.0;
          else hue = (r - g) / delta + 4.0;
          hue /= 6.0;
          if (hue < 0.0) hue += 1.0;
        }
        final bool isSkin = (hue >= 0.0 && hue <= 0.139) && (sat >= 0.15 && sat <= 0.85) && (lum >= 0.20 && lum <= 0.85);
        if (isSkin) {
          final double hueMask = 1.0 - _smoothstep(0.10, 0.139, hue);
          final double satMask = _smoothstep(0.15, 0.25, sat) * (1.0 - _smoothstep(0.75, 0.85, sat));
          final double lumMask = _smoothstep(0.20, 0.35, lum) * (1.0 - _smoothstep(0.75, 0.85, lum));
          final double skinMask = hueMask * satMask * lumMask;
          final double lumVal = 0.2126 * r + 0.7152 * g + 0.0722 * b;
          final double desatR = lumVal + (r - lumVal) * params.skinSatProtect;
          final double desatG = lumVal + (g - lumVal) * params.skinSatProtect;
          final double desatB = lumVal + (b - lumVal) * params.skinSatProtect;
          r += (desatR - r) * skinMask * 0.6;
          g += (desatG - g) * skinMask * 0.6;
          b += (desatB - b) * skinMask * 0.6;
          final double lumBoost = lum * params.skinLumaSoften * 0.8;
          r = (r + lumBoost).clamp(0.0, 1.0);
          g = (g + lumBoost).clamp(0.0, 1.0);
          b = (b + lumBoost).clamp(0.0, 1.0);
          r = r.clamp(0.0, params.skinRedLimit);
        }
      }

      // ── 2. 化学不规则感 ──────────────────────────────────────────────
      if (params.chemicalIrregularity > 0.001) {
        final double ux = x / width.toDouble();
        final double uy = y / payload.height.toDouble();
        final double irregUX = ux * params.irregUvScale;
        final double irregUY = uy * params.irregUvScale;
        final double irreg1 = _random(irregUX * params.irregFreq1, irregUY * params.irregFreq1, 0.0) * 2.0 - 1.0;
        final double irreg2 = _random(irregUX * params.irregFreq2 + 0.3, irregUY * params.irregFreq2 + 0.3, 0.2) * 2.0 - 1.0;
        final double irregularity = irreg1 * params.irregWeight1 + irreg2 * params.irregWeight2;
        final double brightVar = irregularity * params.chemicalIrregularity * 0.03;
        r = (r + brightVar + irregularity * params.chemicalIrregularity * 0.008).clamp(0.0, 1.0);
        g = (g + brightVar + irregularity * params.chemicalIrregularity * 0.004).clamp(0.0, 1.0);
        b = (b + brightVar - irregularity * params.chemicalIrregularity * 0.006).clamp(0.0, 1.0);
      }

      // ── 3. 相纸纹理 ──────────────────────────────────────────────────
      if (params.paperTexture > 0.001) {
        final double ux = x / width.toDouble();
        final double uy = y / payload.height.toDouble();
        final double paper1 = _random(ux * params.paperUvScale1, uy * params.paperUvScale1, 0.0) * 2.0 - 1.0;
        final double paper2 = _random(ux * params.paperUvScale2, uy * params.paperUvScale2, 1.0) * 2.0 - 1.0;
        final double paper = paper1 * params.paperWeight1 + paper2 * params.paperWeight2;
        final double paperOffset = paper * params.paperTexture * 0.04;
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

// 伪随机数生成器，与 Metal Shader 的 instcRandom/sqcRandom 算法一致
double _random(double x, double y, double seed) {
  final dot = x * 12.9898 + y * 78.233 + seed * 43758.5453;
  return (math.sin(dot) * 43758.5453).abs() % 1.0;
}
