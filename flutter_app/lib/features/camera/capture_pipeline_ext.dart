// capture_pipeline_ext.dart
//
// 本文件包含 CapturePipeline 的扩展图像处理函数。
// 这些函数将 GL/Metal Shader 中的效果移植到 Dart，用于成片（CapturePipeline）处理，
// 以消除取景框（GL Shader）与成片之间的视觉差异。
//
// 已移植的效果：
//   1. Tone Curve        — 对应 Shader 中的 fxnrToneCurve() / instcToneCurve()
//   2. Highlight Rolloff — 对应 Shader 中的 uHighlightRolloff2 / highlightRolloff
//   3. Sensor Non-uniformity (Center Gain + Edge Falloff) — 对应 uCenterGain / uEdgeFalloff
//   4. Skin Hue Protection — 对应 uSkinHueProtect / instcSkinProtect()
//   5. Chemical Irregularity — 对应 uChemicalIrregularity / instcChemicalIrregularity()
//   6. Noise — 对应 uNoiseAmount

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

// ─────────────────────────────────────────────────────────────────────────────
// 内部工具函数
// ─────────────────────────────────────────────────────────────────────────────

/// 将处理后的像素数组重新编码为 ui.Image
Future<ui.Image> _pixelsToImage(Uint8List pixels, int width, int height) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final ui.Codec codec = await descriptor.instantiateCodec();
  final ui.FrameInfo frameInfo = await codec.getNextFrame();
  return frameInfo.image;
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Tone Curve
// ─────────────────────────────────────────────────────────────────────────────

/// 对应 Shader 中的 fxnrToneCurve() / instcToneCurve()。
/// 使用分段三次平滑插值，对每个像素的 R/G/B 通道独立应用色调曲线。
///
/// 控制点（归一化）：
///   (0, 0.024) → (0.125, 0.133) → (0.251, 0.267) → (0.502, 0.510) → (0.753, 0.792) → (1.0, 0.973)
/// 效果：黑位抬一点，中间调偏软，高光轻 rolloff，更像即时成像胶片。
Future<ui.Image> drawToneCurve(ui.Image srcImage) async {
  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  for (int i = 0; i < pixels.length; i += 4) {
    pixels[i]     = (_toneCurve(pixels[i]     / 255.0) * 255).round().clamp(0, 255);
    pixels[i + 1] = (_toneCurve(pixels[i + 1] / 255.0) * 255).round().clamp(0, 255);
    pixels[i + 2] = (_toneCurve(pixels[i + 2] / 255.0) * 255).round().clamp(0, 255);
    // alpha 通道 pixels[i + 3] 保持不变
  }

  return _pixelsToImage(pixels, srcImage.width, srcImage.height);
}

/// 分段三次平滑插值（smoothstep 曲线），与 Shader 中的实现完全一致
double _toneCurve(double x) {
  double t;
  if (x < 0.125) {
    t = x / 0.125;
    return 0.024 + (0.133 - 0.024) * (3.0 * t * t - 2.0 * t * t * t);
  } else if (x < 0.251) {
    t = (x - 0.125) / 0.126;
    return 0.133 + (0.267 - 0.133) * (3.0 * t * t - 2.0 * t * t * t);
  } else if (x < 0.502) {
    t = (x - 0.251) / 0.251;
    return 0.267 + (0.510 - 0.267) * (3.0 * t * t - 2.0 * t * t * t);
  } else if (x < 0.753) {
    t = (x - 0.502) / 0.251;
    return 0.510 + (0.792 - 0.510) * (3.0 * t * t - 2.0 * t * t * t);
  } else {
    t = (x - 0.753) / 0.247;
    return 0.792 + (0.973 - 0.792) * (3.0 * t * t - 2.0 * t * t * t);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Highlight Rolloff
// ─────────────────────────────────────────────────────────────────────────────

/// 对应 Shader 中的 instcHighlightRolloff() / uHighlightRolloff2。
/// 将高光区域（亮度 > 0.70）柔和压缩，避免过曝死白。
/// 压缩时偏暖（R 保留更多，B 压缩更多），模拟胶片高光特性。
Future<ui.Image> drawHighlightRolloff(ui.Image srcImage, double rolloff) async {
  if (rolloff < 0.001) return srcImage;

  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  for (int i = 0; i < pixels.length; i += 4) {
    final double r = pixels[i]     / 255.0;
    final double g = pixels[i + 1] / 255.0;
    final double b = pixels[i + 2] / 255.0;

    final double lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    if (lum > 0.70) {
      // 平滑 mask：亮度越高，压缩越强
      double mask = ((lum - 0.70) / 0.30).clamp(0.0, 1.0);
      mask = mask * mask * (3.0 - 2.0 * mask); // smoothstep

      // 偏暖压缩：R 保留最多（×0.15），G 次之（×0.20），B 压缩最多（×0.30）
      pixels[i]     = (r * (1.0 - mask * rolloff * 0.15) * 255).round().clamp(0, 255);
      pixels[i + 1] = (g * (1.0 - mask * rolloff * 0.20) * 255).round().clamp(0, 255);
      pixels[i + 2] = (b * (1.0 - mask * rolloff * 0.30) * 255).round().clamp(0, 255);
    }
  }

  return _pixelsToImage(pixels, srcImage.width, srcImage.height);
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Sensor Non-uniformity（传感器非均匀性）
// ─────────────────────────────────────────────────────────────────────────────

/// 对应 Shader 中的 uCenterGain（中心增亮）和 uEdgeFalloff（边缘曝光衰减）。
///
/// - centerGain：模拟内置闪光灯中心亮度略高的特性（Inst C=0.02，SQC=0.03）
/// - edgeFalloff：模拟即时成像相机不均匀化学显影导致的边缘曝光衰减
Future<ui.Image> drawSensorNonUniformity(
  ui.Image srcImage,
  double centerGain,
  double edgeFalloff, {
  double cornerWarmShift = 0.0,
}) async {
  if (centerGain < 0.001 && edgeFalloff < 0.001) return srcImage;

  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  final int width  = srcImage.width;
  final int height = srcImage.height;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int idx = (y * width + x) * 4;

      // 归一化坐标（0~1），中心为 (0.5, 0.5)
      final double u = x / (width  - 1);
      final double v = y / (height - 1);
      final double dx = u - 0.5;
      final double dy = v - 0.5;
      final double dist2 = dx * dx + dy * dy; // 到中心的距离平方

      // Edge Falloff：边缘衰减（距中心越远越暗）
      // dist2 最大约 0.5（角落），乘以 edgeFalloff 后归一化
      final double falloff = (1.0 - dist2 * 2.0 * edgeFalloff).clamp(0.0, 1.0);

      // Center Gain：中心增亮（偏暖白，模拟闪光灯色温约 5500K）
      // 使用 smoothstep 形状，中心最亮，向外平滑衰减
      final double centerMask = (1.0 - dist2 * 4.0).clamp(0.0, 1.0);
      final double gainR = 1.0 + centerMask * centerGain * 1.2;
      final double gainG = 1.0 + centerMask * centerGain * 1.0;
      final double gainB = 1.0 + centerMask * centerGain * 0.7;

      // Corner Warm Shift：角落色温偏移（负=偏冷青，正=偏暖橙）
      // 仅在角落区域（dist2 > 0.15）应用，平滑过渡
      double shiftR = 0.0, shiftB = 0.0;
      if (cornerWarmShift != 0.0) {
        final double cornerMask = _smoothstep(0.15, 0.45, dist2);
        shiftR = cornerWarmShift * cornerMask;
        shiftB = -cornerWarmShift * cornerMask;
      }

      pixels[idx]     = ((pixels[idx]     / 255.0 * falloff * gainR + shiftR) * 255).round().clamp(0, 255);
      pixels[idx + 1] = (pixels[idx + 1] / 255.0 * falloff * gainG * 255).round().clamp(0, 255);
      pixels[idx + 2] = ((pixels[idx + 2] / 255.0 * falloff * gainB + shiftB) * 255).round().clamp(0, 255);
    }
  }

  return _pixelsToImage(pixels, width, height);
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Skin Hue Protection（肤色保护）
// ─────────────────────────────────────────────────────────────────────────────

/// 对应 Shader 中的 uSkinHueProtect / instcSkinProtect()。
/// 检测肤色区域（Hue 0~50°，Sat 0.15~0.85，Lum 0.2~0.85），
/// 对肤色像素进行饱和度保护，防止肤色过橙/过红。
///
/// 参数：
///   skinHueProtect：1.0 = 开启，0.0 = 关闭
///   skinSatProtect：肤色饱和度保护系数（默认 0.92）
Future<ui.Image> drawSkinHueProtect(
  ui.Image srcImage,
  double skinHueProtect, {
  double satProtect = 0.92,
  double lumaSoften = 0.0,
  double redLimit   = 1.0,
}) async {
  final double skinSatProtect = satProtect;
  if (skinHueProtect < 0.5) return srcImage;

  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  for (int i = 0; i < pixels.length; i += 4) {
    final double r = pixels[i]     / 255.0;
    final double g = pixels[i + 1] / 255.0;
    final double b = pixels[i + 2] / 255.0;

    final List<double> hsl = _rgbToHsl(r, g, b);
    final double h = hsl[0]; // 0.0 ~ 1.0
    final double s = hsl[1];
    final double l = hsl[2];

    // 肤色检测：Hue 0~50°（0.0~0.139），Sat 0.15~0.85，Lum 0.2~0.85
    final bool isSkin = h >= 0.0 && h <= 0.139 &&
                        s >= 0.15 && s <= 0.85 &&
                        l >= 0.20 && l <= 0.85;

    if (isSkin) {
      // 饱和度保护：防止肤色过饱和变橙
      final double newS = s * skinSatProtect;
      final List<double> newRgb = _hslToRgb(h, newS, l);

      // 平滑混合（避免边界突变）
      final double hueMask  = 1.0 - _smoothstep(0.10, 0.139, h);
      final double satMask  = _smoothstep(0.15, 0.25, s) * (1.0 - _smoothstep(0.75, 0.85, s));
      final double lumMask  = _smoothstep(0.20, 0.35, l) * (1.0 - _smoothstep(0.75, 0.85, l));
      final double skinMask = hueMask * satMask * lumMask * 0.6;

      pixels[i]     = (_lerp(r, newRgb[0], skinMask) * 255).round().clamp(0, 255);
      pixels[i + 1] = (_lerp(g, newRgb[1], skinMask) * 255).round().clamp(0, 255);
      pixels[i + 2] = (_lerp(b, newRgb[2], skinMask) * 255).round().clamp(0, 255);
    }
  }

  return _pixelsToImage(pixels, srcImage.width, srcImage.height);
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Chemical Irregularity（化学不规则感）
// ─────────────────────────────────────────────────────────────────────────────

/// 对应 Shader 中的 uChemicalIrregularity / instcChemicalIrregularity()。
/// 模拟胶片化学显影过程中的不均匀性，产生轻微的亮度和色彩随机变化。
///
/// 注意：Shader 中使用低频噪声（基于 UV 坐标的伪随机），
/// 此处使用 Random 模拟，效果近似但不完全相同（成片不需要帧间连续性）。
Future<ui.Image> drawChemicalIrregularity(ui.Image srcImage, double amount) async {
  if (amount < 0.001) return srcImage;

  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  final int width  = srcImage.width;
  final int height = srcImage.height;
  final Random rng = Random();

  // 使用低频块状噪声（每 8x8 像素块共享同一随机值），模拟化学显影的空间相关性
  const int blockSize = 8;
  final int blocksX = (width  / blockSize).ceil();
  final int blocksY = (height / blockSize).ceil();

  // 预生成块噪声
  final List<double> blockNoise = List.generate(
    blocksX * blocksY,
    (_) => rng.nextDouble() * 2.0 - 1.0,
  );

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int idx = (y * width + x) * 4;
      final int bx = x ~/ blockSize;
      final int by = y ~/ blockSize;
      final double irregularity = blockNoise[by * blocksX + bx] * amount;

      // 亮度变化 + 色偏（与 Shader 一致）
      final double brightVar = irregularity * 0.03;
      final double rShift    = irregularity * 0.008;
      final double gShift    = irregularity * 0.004;
      final double bShift    = -irregularity * 0.006;

      pixels[idx]     = (pixels[idx]     / 255.0 + brightVar + rShift).clamp(0.0, 1.0) * 255 ~/ 1;
      pixels[idx + 1] = (pixels[idx + 1] / 255.0 + brightVar + gShift).clamp(0.0, 1.0) * 255 ~/ 1;
      pixels[idx + 2] = (pixels[idx + 2] / 255.0 + brightVar + bShift).clamp(0.0, 1.0) * 255 ~/ 1;
    }
  }

  return _pixelsToImage(pixels, width, height);
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Noise（通用噪声）
// ─────────────────────────────────────────────────────────────────────────────

/// 对应 Shader 中的 uNoiseAmount。
/// 在全图添加均匀随机噪声，模拟传感器噪声或胶片颗粒感。
Future<ui.Image> drawNoise(ui.Image srcImage, double amount) async {
  if (amount < 0.001) return srcImage;

  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  final Random rng = Random();

  for (int i = 0; i < pixels.length; i += 4) {
    // 亮度噪声（R/G/B 同步变化，保持色彩中性）
    final double noise = (rng.nextDouble() - 0.5) * amount * 0.5;
    pixels[i]     = (pixels[i]     / 255.0 + noise).clamp(0.0, 1.0) * 255 ~/ 1;
    pixels[i + 1] = (pixels[i + 1] / 255.0 + noise).clamp(0.0, 1.0) * 255 ~/ 1;
    pixels[i + 2] = (pixels[i + 2] / 255.0 + noise).clamp(0.0, 1.0) * 255 ~/ 1;
  }

  return _pixelsToImage(pixels, srcImage.width, srcImage.height);
}

// ─────────────────────────────────────────────────────────────────────────────
// 内部颜色空间转换工具
// ─────────────────────────────────────────────────────────────────────────────

/// RGB → HSL 转换（H: 0~1，S: 0~1，L: 0~1）
List<double> _rgbToHsl(double r, double g, double b) {
  final double maxVal = [r, g, b].reduce(max);
  final double minVal = [r, g, b].reduce(min);
  double h = 0, s = 0;
  final double l = (maxVal + minVal) / 2.0;

  if (maxVal != minVal) {
    final double d = maxVal - minVal;
    s = l > 0.5 ? d / (2.0 - maxVal - minVal) : d / (maxVal + minVal);
    if (maxVal == r) {
      h = (g - b) / d + (g < b ? 6.0 : 0.0);
    } else if (maxVal == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h /= 6.0;
  }
  return [h, s, l];
}

/// HSL → RGB 转换
List<double> _hslToRgb(double h, double s, double l) {
  if (s == 0) {
    return [l, l, l]; // achromatic
  }
  final double q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
  final double p = 2.0 * l - q;
  return [
    _hue2rgb(p, q, h + 1.0 / 3.0),
    _hue2rgb(p, q, h),
    _hue2rgb(p, q, h - 1.0 / 3.0),
  ];
}

double _hue2rgb(double p, double q, double t) {
  if (t < 0) t += 1.0;
  if (t > 1) t -= 1.0;
  if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
  if (t < 1.0 / 2.0) return q;
  if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
  return p;
}

/// smoothstep 函数（与 GLSL 内置函数一致）
double _smoothstep(double edge0, double edge1, double x) {
  final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// 线性插值
double _lerp(double a, double b, double t) => a + (b - a) * t;


// ─────────────────────────────────────────────────────────────────────────────
// 7. Paper Texture (相纸纹理)
// ─────────────────────────────────────────────────────────────────────────────
Future<ui.Image> drawPaperTexture(ui.Image srcImage, double amount) async {
  if (amount < 0.001) return srcImage;

  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  final Random rng = Random();

  for (int i = 0; i < pixels.length; i += 4) {
    final double noise = (rng.nextDouble() - 0.5) * amount * 0.1;
    pixels[i]     = (pixels[i]     / 255.0 + noise).clamp(0.0, 1.0) * 255 ~/ 1;
    pixels[i + 1] = (pixels[i + 1] / 255.0 + noise).clamp(0.0, 1.0) * 255 ~/ 1;
    pixels[i + 2] = (pixels[i + 2] / 255.0 + noise).clamp(0.0, 1.0) * 255 ~/ 1;
  }

  return _pixelsToImage(pixels, srcImage.width, srcImage.height);
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Development Softness (显影柔化)
// ─────────────────────────────────────────────────────────────────────────────
Future<ui.Image> drawDevelopmentSoftness(ui.Image srcImage, double amount) async {
  if (amount < 0.001) return srcImage;

  // This is a simplified version. A proper implementation would require a blur filter.
  // For now, we apply a slight desaturation to simulate softness.
  final ByteData? byteData = await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return srcImage;

  final Uint8List pixels = byteData.buffer.asUint8List();
  for (int i = 0; i < pixels.length; i += 4) {
    final double r = pixels[i] / 255.0;
    final double g = pixels[i+1] / 255.0;
    final double b = pixels[i+2] / 255.0;
    final double lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    pixels[i] = ((r * (1.0 - amount)) + lum * amount) * 255 ~/ 1;
    pixels[i+1] = ((g * (1.0 - amount)) + lum * amount) * 255 ~/ 1;
    pixels[i+2] = ((b * (1.0 - amount)) + lum * amount) * 255 ~/ 1;
  }

  return _pixelsToImage(pixels, srcImage.width, srcImage.height);
}


/// 构建用于 Highlight Rolloff 的 256-entry 查找表 (LUT)
///
/// 预计算每个亮度级别的滚落系数，避免逐像素计算。
Float32List buildHighlightRolloffLUT(double rolloff) {
  final lut = Float32List(256);
  if (rolloff < 0.001) return lut;

  for (int i = 0; i < 256; i++) {
    final double lum = i / 255.0;
    if (lum > 0.70) {
      final double t = (lum - 0.70) / 0.30;
      lut[i] = t * t * (3.0 - 2.0 * t) * rolloff;
    } else {
      lut[i] = 0.0;
    }
  }
  return lut;
}

/// 构建用于 Sensor Non-uniformity 的权重表
///
/// 预计算每个像素的增益/衰减系数，避免逐像素坐标计算。
Float32List buildSensorNonUniformityTable(int width, int height, double centerGain, double edgeFalloff, {double cornerWarmShift = 0.0}) {
  final table = Float32List(width * height * 3);
  if (centerGain < 0.001 && edgeFalloff < 0.001 && cornerWarmShift.abs() < 0.001) return table;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int i = y * width + x;
      final double u = x / (width - 1) - 0.5;
      final double v = y / (height - 1) - 0.5;
      final double dist2 = u * u + v * v;

      // Edge Falloff
      final double falloff = (1.0 - dist2 * 2.0 * edgeFalloff).clamp(0.0, 1.0);

      // Center Gain
      final double centerMask = (1.0 - dist2 * 4.0).clamp(0.0, 1.0);
      final double gainR = 1.0 + centerMask * centerGain * 1.2;
      final double gainG = 1.0 + centerMask * centerGain;
      final double gainB = 1.0 + centerMask * centerGain * 0.7;

      // Corner Warm Shift
      double shiftR = 0.0, shiftB = 0.0;
      if (cornerWarmShift.abs() > 0.001) {
        final double cornerMask = (dist2 - 0.15).clamp(0.0, 0.3) / 0.3;
        shiftR = cornerWarmShift * cornerMask;
        shiftB = -cornerWarmShift * cornerMask;
      }

      table[i * 3]     = falloff * gainR + shiftR;
      table[i * 3 + 1] = falloff * gainG;
      table[i * 3 + 2] = falloff * gainB + shiftB;
    }
  }
  return table;
}
