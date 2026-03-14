import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../models/camera_definition.dart';
import 'preview_renderer.dart';

/// 捕获后处理管线
/// 顺序：比例裁剪 → 颜色效果 → 暗角 → 相纸边框 → 水印 → 输出 PNG
class CapturePipeline {
  final CameraDefinition camera;

  CapturePipeline({required this.camera});

  /// 处理拍摄的图片文件，返回处理后的 PNG 字节
  Future<Uint8List?> process({
    required String imagePath,
    required String selectedRatioId,
    required String selectedFrameId,
    required String selectedWatermarkId,
    PreviewRenderParams? renderParams,
  }) async {
    try {
      // ── 1. 读取原始图片 ──────────────────────────────────────────────────────
      final bytes = await File(imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;

      final srcW = srcImage.width.toDouble();
      final srcH = srcImage.height.toDouble();

      debugPrint('[CapturePipeline] src: ${srcW}x${srcH}, ratio=$selectedRatioId, frame=$selectedFrameId, wm=$selectedWatermarkId');

      // ── 2. 计算裁剪区域（保持中心裁剪）────────────────────────────────────────
      final cropRect = _calcCropRect(srcW, srcH, selectedRatioId);
      double outW = cropRect.width;
      double outH = cropRect.height;

      debugPrint('[CapturePipeline] crop: ${outW}x${outH}');

      // ── 3. 边框 inset 计算（在裁剪后尺寸上扩展画布）──────────────────────────
      // inset 值是像素，相对于 1080px 参考宽度
      double topPx = 0, rightPx = 0, bottomPx = 0, leftPx = 0;
      FrameDefinition? frameOpt;
      if (selectedFrameId.isNotEmpty &&
          selectedFrameId != 'frame_none' &&
          selectedFrameId != 'none') {
        try {
          frameOpt = camera.modules.frames.firstWhere((f) => f.id == selectedFrameId);
          // 以图片短边为参考，确保边框比例一致
          final refSize = math.min(outW, outH);
          final scale = refSize / 1080.0;
          topPx = frameOpt.inset.top * scale;
          rightPx = frameOpt.inset.right * scale;
          bottomPx = frameOpt.inset.bottom * scale;
          leftPx = frameOpt.inset.left * scale;
          debugPrint('[CapturePipeline] frame inset: t=$topPx r=$rightPx b=$bottomPx l=$leftPx');
        } catch (_) {
          frameOpt = null;
        }
      }

      // 最终画布尺寸 = 裁剪尺寸 + 边框
      final canvasW = outW + leftPx + rightPx;
      final canvasH = outH + topPx + bottomPx;

      // ── 4. 创建画布 ──────────────────────────────────────────────────────────
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, canvasW, canvasH));

      // ── 4a. 先填充边框背景色 ──────────────────────────────────────────────────
      if (frameOpt != null) {
        Color bgColor = const Color(0xFFF5F2EA);
        try {
          final hex = frameOpt.backgroundColor.replaceAll('#', '');
          bgColor = Color(int.parse('FF$hex', radix: 16));
        } catch (_) {}
        canvas.drawRect(
          Rect.fromLTWH(0, 0, canvasW, canvasH),
          Paint()..color = bgColor,
        );
      }

      // ── 4b. 绘制裁剪后的图片（带颜色效果）到边框内区域 ─────────────────────────
      final destRect = Rect.fromLTWH(leftPx, topPx, outW, outH);
      if (renderParams != null) {
        final colorMatrix = _buildColorMatrix(renderParams);
        canvas.drawImageRect(
          srcImage,
          cropRect,
          destRect,
          Paint()
            ..filterQuality = FilterQuality.high
            ..colorFilter = ColorFilter.matrix(colorMatrix),
        );
      } else {
        canvas.drawImageRect(
          srcImage,
          cropRect,
          destRect,
          Paint()..filterQuality = FilterQuality.high,
        );
      }

      // ── 4c. 暗角（只在图片区域内绘制）──────────────────────────────────────────
      if (renderParams != null && renderParams.effectiveVignette > 0.01) {
        _drawVignette(canvas, leftPx, topPx, outW, outH, renderParams.effectiveVignette);
      }

      // ── 4d. 水印（绘制在图片区域内，靠近边框内侧）──────────────────────────────
      if (selectedWatermarkId.isNotEmpty && selectedWatermarkId != 'none') {
        _drawWatermark(canvas, leftPx, topPx, outW, outH, selectedWatermarkId);
      }

      // ── 5. 输出为 PNG ────────────────────────────────────────────────────────
      final picture = recorder.endRecording();
      final outputImage =
          await picture.toImage(canvasW.toInt(), canvasH.toInt());
      final byteData =
          await outputImage.toByteData(format: ui.ImageByteFormat.rawRgba);

      if (byteData == null) return null;

      final pngBytes = await _rgbaToImage(
        byteData.buffer.asUint8List(),
        canvasW.toInt(),
        canvasH.toInt(),
      );
      debugPrint('[CapturePipeline] output: ${canvasW.toInt()}x${canvasH.toInt()}, bytes=${pngBytes.length}');
      return pngBytes;
    } catch (e, st) {
      debugPrint('[CapturePipeline] Error: $e\n$st');
      return null;
    }
  }

  // ── 比例裁剪（中心裁剪，保持目标宽高比）────────────────────────────────────────

  Rect _calcCropRect(double w, double h, String ratioId) {
    // 找到对应的 ratio 定义
    RatioDefinition? ratioOpt;
    if (ratioId.isNotEmpty) {
      try {
        ratioOpt = camera.modules.ratios.firstWhere((r) => r.id == ratioId);
      } catch (_) {}
    }
    ratioOpt ??= camera.modules.ratios.isNotEmpty ? camera.modules.ratios.first : null;

    if (ratioOpt == null) return Rect.fromLTWH(0, 0, w, h);

    // targetRatio = width / height（例如 3:4 = 0.75）
    final targetRatio = ratioOpt.width.toDouble() / ratioOpt.height.toDouble();
    final srcRatio = w / h;

    double cropW, cropH, cropX, cropY;

    if (srcRatio > targetRatio) {
      // 原图更宽，裁左右
      cropH = h;
      cropW = h * targetRatio;
      cropX = (w - cropW) / 2;
      cropY = 0;
    } else {
      // 原图更高，裁上下
      cropW = w;
      cropH = w / targetRatio;
      cropX = 0;
      cropY = (h - cropH) / 2;
    }

    debugPrint('[CapturePipeline] ratio=${ratioOpt.label} targetRatio=$targetRatio srcRatio=$srcRatio crop=${cropW}x${cropH}@($cropX,$cropY)');
    return Rect.fromLTWH(cropX, cropY, cropW, cropH);
  }

  // ── 颜色矩阵（与预览一致）────────────────────────────────────────────────────

  List<double> _buildColorMatrix(PreviewRenderParams params) {
    var m = _identity();

    // 曝光
    final expMul = math.pow(2.0, params.exposureOffset).toDouble();
    m = _multiply(m, _exposureMatrix(expMul));

    // 色温
    if (params.policy.enableTemperature) {
      m = _multiply(m, _temperatureMatrix(params.effectiveTemperature));
    }

    // 对比度
    if (params.policy.enableContrast) {
      m = _multiply(m, _contrastMatrix(params.effectiveContrast));
    }

    // 饱和度
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
    final rShift = t * 0.20;   // warm: +red, cool: -red
    final bShift = -t * 0.20;  // warm: -blue, cool: +blue
    // Green stays neutral to avoid purple/magenta cast on cool temperatures
    return [
      1 + rShift, 0, 0, 0, 0,
      0, 1.0, 0, 0, 0,
      0, 0, 1 + bShift, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _contrastMatrix(double contrast) {
    final offset = 0.5 * (1 - contrast);
    return [
      contrast, 0, 0, 0, offset * 255,
      0, contrast, 0, 0, offset * 255,
      0, 0, contrast, 0, offset * 255,
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

  // ── 暗角（绘制在图片区域内）──────────────────────────────────────────────────

  void _drawVignette(
      Canvas canvas, double ox, double oy, double w, double h, double strength) {
    final center = Offset(ox + w / 2, oy + h / 2);
    final radius = math.sqrt(w * w + h * h) / 2;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.transparent,
          Colors.black.withAlpha((strength * 220).clamp(0, 220).toInt()),
        ],
        stops: const [0.45, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Rect.fromLTWH(ox, oy, w, h), paint);
  }

  // ── 水印（绘制在图片区域内）──────────────────────────────────────────────────

  void _drawWatermark(
      Canvas canvas, double ox, double oy, double w, double h, String watermarkId) {
    final wmPresets = camera.modules.watermarks.presets;
    if (wmPresets.isEmpty) return;

    WatermarkPreset? wmOpt;
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

    final fontSize = (w * 0.038).clamp(14.0, 90.0);

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontFamily: wmOpt.fontFamily,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);

    final position = wmOpt.position ?? 'bottom_right';
    final margin = w * 0.04;
    double dx, dy;
    switch (position) {
      case 'bottom_right':
        dx = ox + w - textPainter.width - margin;
        dy = oy + h - textPainter.height - margin;
        break;
      case 'bottom_left':
        dx = ox + margin;
        dy = oy + h - textPainter.height - margin;
        break;
      case 'top_right':
        dx = ox + w - textPainter.width - margin;
        dy = oy + margin;
        break;
      case 'top_left':
        dx = ox + margin;
        dy = oy + margin;
        break;
      default:
        dx = ox + w - textPainter.width - margin;
        dy = oy + h - textPainter.height - margin;
    }

    textPainter.paint(canvas, Offset(dx, dy));
  }

  // ── RGBA bytes → PNG bytes ────────────────────────────────────────────────

  Future<Uint8List> _rgbaToImage(Uint8List rgba, int w, int h) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
    final img = await completer.future;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}
