import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../models/camera_definition.dart';
import 'preview_renderer.dart';

/// 捕获后处理管线
/// 顺序：颜色效果 → 比例裁剪 → 相纸边框叠加 → 水印合成 → 输出 JPEG
class CapturePipeline {
  final CameraDefinition camera;

  CapturePipeline({required this.camera});

  /// 处理拍摄的图片文件
  Future<Uint8List?> process({
    required String imagePath,
    required String selectedRatioId,
    required String selectedFrameId,
    required String selectedWatermarkId,
    PreviewRenderParams? renderParams,
  }) async {
    try {
      // 1. 读取原始图片
      final bytes = await File(imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;

      final srcW = srcImage.width.toDouble();
      final srcH = srcImage.height.toDouble();

      // 2. 计算裁剪区域
      final cropRect = _calcCropRect(srcW, srcH, selectedRatioId);
      final outW = cropRect.width;
      final outH = cropRect.height;

      // 3. 创建画布进行合成
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // 3a. 绘制裁剪后的原始图片，应用颜色效果
      if (renderParams != null) {
        final colorMatrix = _buildColorMatrix(renderParams);
        final paint = Paint()
          ..filterQuality = FilterQuality.high
          ..colorFilter = ColorFilter.matrix(colorMatrix);
        canvas.drawImageRect(
          srcImage,
          cropRect,
          Rect.fromLTWH(0, 0, outW, outH),
          paint,
        );
      } else {
        final paint = Paint()..filterQuality = FilterQuality.high;
        canvas.drawImageRect(
          srcImage,
          cropRect,
          Rect.fromLTWH(0, 0, outW, outH),
          paint,
        );
      }

      // 3b. 叠加暗角
      if (renderParams != null && renderParams.effectiveVignette > 0.01) {
        _drawVignette(canvas, outW, outH, renderParams.effectiveVignette);
      }

      // 3c. 叠加相纸边框
      final frameId = selectedFrameId;
      if (frameId.isNotEmpty && frameId != 'frame_none' && frameId != 'none') {
        _drawFrame(canvas, outW, outH, frameId);
      }

      // 3d. 叠加水印
      if (selectedWatermarkId.isNotEmpty && selectedWatermarkId != 'none') {
        _drawWatermark(canvas, outW, outH, selectedWatermarkId);
      }

      // 4. 输出为 JPEG
      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(outW.toInt(), outH.toInt());
      final byteData =
          await outputImage.toByteData(format: ui.ImageByteFormat.rawRgba);

      if (byteData == null) return null;

      // Re-encode as PNG (JPEG encoding not directly available in dart:ui)
      final pngCodec = await ui.instantiateImageCodec(
        await _rgbaToImage(byteData.buffer.asUint8List(), outW.toInt(), outH.toInt()),
      );
      final pngFrame = await pngCodec.getNextFrame();
      final pngData = await pngFrame.image.toByteData(format: ui.ImageByteFormat.png);
      return pngData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[CapturePipeline] Error: $e');
      return null;
    }
  }

  // ── Color matrix (same as preview) ────────────────────────────────────────

  List<double> _buildColorMatrix(PreviewRenderParams params) {
    var m = _identity();

    // Exposure
    final expMul = math.pow(2.0, params.exposureOffset).toDouble();
    m = _multiply(m, _exposureMatrix(expMul));

    // Temperature
    if (params.policy.enableTemperature) {
      m = _multiply(m, _temperatureMatrix(params.effectiveTemperature));
    }

    // Contrast
    if (params.policy.enableContrast) {
      m = _multiply(m, _contrastMatrix(params.effectiveContrast));
    }

    // Saturation
    if (params.policy.enableSaturation) {
      m = _multiply(m, _saturationMatrix(params.effectiveSaturation));
    }

    return m;
  }

  List<double> _identity() => [
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  List<double> _exposureMatrix(double mul) => [
    mul, 0, 0, 0, 0,
    0, mul, 0, 0, 0,
    0, 0, mul, 0, 0,
    0, 0, 0, 1, 0,
  ];

  List<double> _temperatureMatrix(double temp) {
    final t = temp / 100.0;
    final rShift = t * 0.15;
    final bShift = -t * 0.15;
    final gShift = t * 0.05;
    return [
      1 + rShift, 0, 0, 0, 0,
      0, 1 + gShift, 0, 0, 0,
      0, 0, 1 + bShift, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _contrastMatrix(double contrast) {
    final offset = 0.5 * (1 - contrast);
    return [
      contrast, 0, 0, 0, offset,
      0, contrast, 0, 0, offset,
      0, 0, contrast, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _saturationMatrix(double sat) {
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final sr = (1 - sat) * lr;
    final sg = (1 - sat) * lg;
    final sb = (1 - sat) * lb;
    return [
      sr + sat, sg, sb, 0, 0,
      sr, sg + sat, sb, 0, 0,
      sr, sg, sb + sat, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _multiply(List<double> a, List<double> b) {
    final result = List<double>.filled(20, 0);
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 5; col++) {
        double sum = 0;
        for (int k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) {
          sum += a[row * 5 + 4];
        }
        result[row * 5 + col] = sum;
      }
    }
    return result;
  }

  // ── 暗角 ──────────────────────────────────────────────────────────────────

  void _drawVignette(Canvas canvas, double w, double h, double strength) {
    final center = Offset(w / 2, h / 2);
    final radius = math.sqrt(w * w + h * h) / 2;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.transparent,
          Colors.black.withAlpha((strength * 200).clamp(0, 200).toInt()),
        ],
        stops: const [0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), paint);
  }

  // ── 比例裁剪 ──────────────────────────────────────────────────────────────

  Rect _calcCropRect(double w, double h, String ratioId) {
    final ratios = camera.modules.ratios;
    if (ratios.isEmpty) return Rect.fromLTWH(0, 0, w, h);

    RatioDefinition ratioOpt;
    try {
      ratioOpt = ratios.firstWhere((r) => r.id == ratioId);
    } catch (_) {
      ratioOpt = ratios.first;
    }

    final targetRatio = ratioOpt.aspectRatio;
    final srcRatio = w / h;

    double cropW, cropH, cropX, cropY;

    if (srcRatio > targetRatio) {
      cropH = h;
      cropW = h * targetRatio;
      cropX = (w - cropW) / 2;
      cropY = 0;
    } else {
      cropW = w;
      cropH = w / targetRatio;
      cropX = 0;
      cropY = (h - cropH) / 2;
    }

    return Rect.fromLTWH(cropX, cropY, cropW, cropH);
  }

  // ── 相纸边框 ──────────────────────────────────────────────────────────────

  void _drawFrame(Canvas canvas, double w, double h, String frameId) {
    final frames = camera.modules.frames;
    if (frames.isEmpty) return;

    FrameDefinition frameOpt;
    try {
      frameOpt = frames.firstWhere((f) => f.id == frameId);
    } catch (_) {
      return;
    }

    Color bgColor = Colors.white;
    try {
      final hex = frameOpt.backgroundColor.replaceAll('#', '');
      bgColor = Color(int.parse('FF$hex', radix: 16));
    } catch (_) {}

    // inset values are in pixels (absolute), not ratios
    final inset = frameOpt.inset;
    // Use fixed pixel inset (the JSON values are in pixels relative to a reference size)
    // Scale to actual image size: reference size is ~1080px wide
    final scale = w / 1080.0;
    final topPx = inset.top * scale;
    final rightPx = inset.right * scale;
    final bottomPx = inset.bottom * scale;
    final leftPx = inset.left * scale;

    final paint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;

    if (topPx > 0) canvas.drawRect(Rect.fromLTWH(0, 0, w, topPx), paint);
    if (bottomPx > 0) canvas.drawRect(Rect.fromLTWH(0, h - bottomPx, w, bottomPx), paint);
    if (leftPx > 0) canvas.drawRect(Rect.fromLTWH(0, 0, leftPx, h), paint);
    if (rightPx > 0) canvas.drawRect(Rect.fromLTWH(w - rightPx, 0, rightPx, h), paint);
  }

  // ── 水印 ──────────────────────────────────────────────────────────────────

  void _drawWatermark(Canvas canvas, double w, double h, String watermarkId) {
    final wmPresets = camera.modules.watermarks.presets;
    if (wmPresets.isEmpty) return;

    WatermarkPreset wmOpt;
    try {
      wmOpt = wmPresets.firstWhere((wm) => wm.id == watermarkId);
    } catch (_) {
      return;
    }

    if (wmOpt.isNone) return;

    final now = DateTime.now();
    final text =
        "${now.year.toString().substring(2)}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}";

    Color textColor = const Color(0xFFFF8C00);
    if (wmOpt.color != null && wmOpt.color!.isNotEmpty) {
      try {
        final hex = wmOpt.color!.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    // fontSize in JSON is in sp; scale to image size
    final fontSize = (w * 0.035).clamp(12.0, 80.0);

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontFamily: wmOpt.fontFamily ?? 'monospace',
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);

    final position = wmOpt.position ?? 'bottom_right';
    double dx, dy;
    switch (position) {
      case 'bottom_right':
        dx = w - textPainter.width - w * 0.03;
        dy = h - textPainter.height - h * 0.03;
        break;
      case 'bottom_left':
        dx = w * 0.03;
        dy = h - textPainter.height - h * 0.03;
        break;
      case 'top_right':
        dx = w - textPainter.width - w * 0.03;
        dy = h * 0.03;
        break;
      case 'top_left':
        dx = w * 0.03;
        dy = h * 0.03;
        break;
      default:
        dx = w - textPainter.width - w * 0.03;
        dy = h - textPainter.height - h * 0.03;
    }

    textPainter.paint(canvas, Offset(dx, dy));
  }

  // ── Helper: encode RGBA bytes to PNG via ui.Image ─────────────────────────

  Future<Uint8List> _rgbaToImage(Uint8List rgba, int w, int h) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
    final img = await completer.future;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}
