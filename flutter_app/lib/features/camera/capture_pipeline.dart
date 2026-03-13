import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/camera_definition.dart';

/// 捕获后处理管线
/// 顺序：比例裁剪 → 相纸边框叠加 → 水印合成 → 输出 PNG
class CapturePipeline {
  final CameraDefinition camera;

  CapturePipeline({required this.camera});

  /// 处理拍摄的图片文件
  Future<Uint8List?> process({
    required String imagePath,
    required String selectedRatioId,
    required String selectedFrameId,
    required String selectedWatermarkId,
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

      // 3a. 绘制裁剪后的原始图片
      final paint = Paint()..filterQuality = FilterQuality.high;
      canvas.drawImageRect(
        srcImage,
        cropRect,
        Rect.fromLTWH(0, 0, outW, outH),
        paint,
      );

      // 3b. 叠加相纸边框
      if (selectedFrameId.isNotEmpty && selectedFrameId != 'none') {
        _drawFrame(canvas, outW, outH, selectedFrameId);
      }

      // 3c. 叠加水印
      if (selectedWatermarkId.isNotEmpty && selectedWatermarkId != 'none') {
        _drawWatermark(canvas, outW, outH, selectedWatermarkId);
      }

      // 4. 输出为 PNG
      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(outW.toInt(), outH.toInt());
      final byteData =
          await outputImage.toByteData(format: ui.ImageByteFormat.png);

      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[CapturePipeline] Error: $e');
      return null;
    }
  }

  // ── 比例裁剪 ──────────────────────────────────────────────────────────────

  Rect _calcCropRect(double w, double h, String ratioId) {
    final ratios = camera.modules.ratios;
    final ratioOpt = ratios.firstWhere(
      (r) => r.id == ratioId,
      orElse: () => ratios.first,
    );

    final targetRatio = ratioOpt.aspectRatio; // width / height
    final srcRatio = w / h;

    double cropW, cropH, cropX, cropY;

    if (srcRatio > targetRatio) {
      // 原图更宽，裁剪左右
      cropH = h;
      cropW = h * targetRatio;
      cropX = (w - cropW) / 2;
      cropY = 0;
    } else {
      // 原图更高，裁剪上下
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
    final frameOpt = frames.firstWhere(
      (f) => f.id == frameId,
      orElse: () => frames.first,
    );

    // 解析背景色
    Color bgColor = Colors.white;
    try {
      final hex = frameOpt.backgroundColor.replaceAll('#', '');
      bgColor = Color(int.parse('FF$hex', radix: 16));
    } catch (_) {}

    // 使用 inset 绘制边框（inset 是相对于图片尺寸的比例）
    final inset = frameOpt.inset;
    final topPx = h * inset.top;
    final rightPx = w * inset.right;
    final bottomPx = h * inset.bottom;
    final leftPx = w * inset.left;

    final paint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;

    // 上边框
    if (topPx > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, topPx), paint);
    }
    // 下边框
    if (bottomPx > 0) {
      canvas.drawRect(Rect.fromLTWH(0, h - bottomPx, w, bottomPx), paint);
    }
    // 左边框
    if (leftPx > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, leftPx, h), paint);
    }
    // 右边框
    if (rightPx > 0) {
      canvas.drawRect(Rect.fromLTWH(w - rightPx, 0, rightPx, h), paint);
    }
  }

  // ── 水印 ──────────────────────────────────────────────────────────────────

  void _drawWatermark(Canvas canvas, double w, double h, String watermarkId) {
    final wmPresets = camera.modules.watermarks.presets;
    final wmOpt = wmPresets.firstWhere(
      (wm) => wm.id == watermarkId,
      orElse: () => wmPresets.first,
    );

    if (wmOpt.isNone) return;

    // 时间戳水印
    final now = DateTime.now();
    final text =
        "${now.year.toString().substring(2)}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}";

    // 解析颜色
    Color textColor = const Color(0xFFFF8C00);
    if (wmOpt.color != null && wmOpt.color!.isNotEmpty) {
      try {
        final hex = wmOpt.color!.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    final fontSize = ((wmOpt.fontSize ?? 0.035) * w).clamp(12.0, 80.0);

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

    // 根据位置配置绘制
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
}
