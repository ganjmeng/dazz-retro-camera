import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/camera_definition.dart';

// ─── 图像处理管线（捕获时使用）────────────────────────────────────────────────
// 负责：比例裁剪 → 相纸边框合成 → 水印叠加 → 导出 JPEG
class ImageProcessor {
  // ── 主入口：处理原始照片 ────────────────────────────────────────────────────
  static Future<Uint8List?> processCapture({
    required Uint8List rawImageBytes,
    required CameraSelectionState selection,
  }) async {
    try {
      // 1. 解码原始图像
      final codec = await ui.instantiateImageCodec(rawImageBytes);
      final frame = await codec.getNextFrame();
      ui.Image image = frame.image;

      final camera = selection.camera;
      final exportPolicy = camera.exportPolicy;

      // 2. 比例裁剪
      if (exportPolicy.applyRatioCrop && selection.selectedRatio != null) {
        image = await _cropToRatio(image, selection.selectedRatio!.aspectRatio);
      }

      // 3. 相纸边框合成（Polaroid 等）
      if (exportPolicy.applyPaperComposite && selection.hasPaper) {
        image = await _applyPaperFrame(image, selection.selectedPaper!);
      }

      // 4. 水印叠加
      if (exportPolicy.applyWatermark && selection.hasWatermark) {
        image = await _applyWatermark(image, selection.selectedWatermark!);
      }

      // 5. 编码为 JPEG
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      return byteData.buffer.asUint8List();
    } catch (e) {
      return null;
    }
  }

  // ── 比例裁剪 ────────────────────────────────────────────────────────────────
  static Future<ui.Image> _cropToRatio(
      ui.Image image, double targetRatio) async {
    final srcW = image.width.toDouble();
    final srcH = image.height.toDouble();
    final srcRatio = srcW / srcH;

    double cropW, cropH, offsetX, offsetY;

    if (srcRatio > targetRatio) {
      // 图像更宽，裁剪左右
      cropH = srcH;
      cropW = srcH * targetRatio;
      offsetX = (srcW - cropW) / 2;
      offsetY = 0;
    } else {
      // 图像更高，裁剪上下
      cropW = srcW;
      cropH = srcW / targetRatio;
      offsetX = 0;
      offsetY = (srcH - cropH) / 2;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(offsetX, offsetY, cropW, cropH),
      Rect.fromLTWH(0, 0, cropW, cropH),
      Paint(),
    );
    final picture = recorder.endRecording();
    return picture.toImage(cropW.round(), cropH.round());
  }

  // ── 相纸边框合成 ─────────────────────────────────────────────────────────────
  static Future<ui.Image> _applyPaperFrame(
      ui.Image image, PaperOption paper) async {
    final r = paper.rendering;
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();

    // 计算带边距的画布尺寸
    final totalW = imgW / (1 - r.marginLeft - r.marginRight);
    final totalH = imgH / (1 - r.marginTop - r.marginBottom);
    final offsetX = totalW * r.marginLeft;
    final offsetY = totalH * r.marginTop;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder,
        Rect.fromLTWH(0, 0, totalW, totalH));

    // 背景色
    final bgColor = _parseColor(r.backgroundColor);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, totalW, totalH),
      Paint()..color = bgColor,
    );

    // 绘制照片
    canvas.drawImage(image, Offset(offsetX, offsetY), Paint());

    // 如果有边框图片资源，叠加边框
    if (r.frameAsset != null) {
      try {
        final frameImage = await _loadAssetImage(r.frameAsset!);
        canvas.drawImageRect(
          frameImage,
          Rect.fromLTWH(0, 0, frameImage.width.toDouble(),
              frameImage.height.toDouble()),
          Rect.fromLTWH(0, 0, totalW, totalH),
          Paint(),
        );
      } catch (_) {
        // 边框资源不存在时跳过
      }
    }

    final picture = recorder.endRecording();
    return picture.toImage(totalW.round(), totalH.round());
  }

  // ── 水印叠加 ────────────────────────────────────────────────────────────────
  static Future<ui.Image> _applyWatermark(
      ui.Image image, WatermarkOption watermark) async {
    if (watermark.isNone) return image;

    final w = image.width.toDouble();
    final h = image.height.toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    // 绘制原图
    canvas.drawImage(image, Offset.zero, Paint());

    // 计算水印文本
    final text = _buildWatermarkText(watermark);
    if (text.isEmpty) return image;

    final color = _parseColor(watermark.rendering.color);
    final opacity = watermark.rendering.opacity.clamp(0.0, 1.0);
    final fontSize = (watermark.rendering.fontSize * w / 375.0).clamp(10.0, 48.0);

    final textStyle = TextStyle(
      color: color.withOpacity(opacity),
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
    );

    final textPainter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(maxWidth: w * 0.5);

    final padding = w * 0.03;
    final position = watermark.rendering.position;
    Offset offset;

    switch (position) {
      case 'bottom_right':
        offset = Offset(
          w - textPainter.width - padding,
          h - textPainter.height - padding,
        );
        break;
      case 'bottom_left':
        offset = Offset(padding, h - textPainter.height - padding);
        break;
      case 'top_left':
        offset = Offset(padding, padding);
        break;
      case 'top_right':
        offset = Offset(w - textPainter.width - padding, padding);
        break;
      case 'frame_bottom':
        // 在相纸底部居中
        offset = Offset(
          (w - textPainter.width) / 2,
          h - textPainter.height - padding * 0.5,
        );
        break;
      default:
        offset = Offset(
          w - textPainter.width - padding,
          h - textPainter.height - padding,
        );
    }

    textPainter.paint(canvas, offset);

    final picture = recorder.endRecording();
    return picture.toImage(w.round(), h.round());
  }

  // ── 构建水印文本 ─────────────────────────────────────────────────────────────
  static String _buildWatermarkText(WatermarkOption watermark) {
    switch (watermark.type) {
      case 'digital_date':
        final now = DateTime.now();
        return "${now.year.toString().substring(2)}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}";
      case 'camera_name':
        return watermark.rendering.textFormat ?? '';
      case 'frame_text':
        return watermark.rendering.textFormat ?? '';
      case 'video_rec':
        return watermark.rendering.textFormat ?? '● REC';
      default:
        return '';
    }
  }

  // ── 加载 Asset 图片 ──────────────────────────────────────────────────────────
  static Future<ui.Image> _loadAssetImage(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  // ── 解析颜色字符串 ───────────────────────────────────────────────────────────
  static Color _parseColor(String hex) {
    try {
      final cleaned = hex.replaceAll('#', '');
      if (cleaned.length == 6) {
        return Color(int.parse('FF$cleaned', radix: 16));
      } else if (cleaned.length == 8) {
        return Color(int.parse(cleaned, radix: 16));
      }
    } catch (_) {}
    return const Color(0xFFFF8A3D);
  }

  // ── 应用颜色滤镜（预览用）────────────────────────────────────────────────────
  /// 根据 FilmRendering 参数生成 ColorFilter 矩阵
  static ColorFilter buildPreviewColorFilter({
    required double contrast,
    required double saturation,
    required double brightness,
    required double temperatureShift,
    required double vignetteAmount,
    required double fadeAmount,
  }) {
    // 构建 5x4 颜色矩阵
    // 格式: [R, G, B, A, offset] × 4行
    // 先应用亮度、对比度、饱和度
    final s = saturation.clamp(0.0, 3.0);
    final c = contrast.clamp(0.1, 3.0);
    final b = brightness.clamp(-1.0, 1.0);

    // 饱和度矩阵（NTSC 系数）
    final lr = 0.2126 * (1 - s);
    final lg = 0.7152 * (1 - s);
    final lb = 0.0722 * (1 - s);

    // 对比度偏移（使中间调不变）
    final cOffset = (1 - c) / 2 + b;

    // 色温偏移（-1000 ~ +1000 映射到 -0.1 ~ +0.1 的 RGB 偏移）
    final tempNorm = (temperatureShift / 1000.0).clamp(-0.15, 0.15);
    final rShift = tempNorm * 0.8;  // 暖色增加红
    final bShift = -tempNorm * 0.6; // 暖色减少蓝

    // 褪色：将黑色提亮（lift shadows）
    final fadeOffset = fadeAmount * 0.15;

    final matrix = [
      // R
      (lr + s) * c, lg * c,       lb * c,       0.0, cOffset + rShift + fadeOffset,
      // G
      lr * c,       (lg + s) * c, lb * c,       0.0, cOffset + fadeOffset * 0.5,
      // B
      lr * c,       lg * c,       (lb + s) * c, 0.0, cOffset + bShift + fadeOffset,
      // A
      0.0,          0.0,          0.0,          1.0, 0.0,
    ];

    return ColorFilter.matrix(matrix);
  }

  // ── 保存图片到临时文件 ───────────────────────────────────────────────────────
  static Future<String?> saveToTemp(Uint8List bytes, String filename) async {
    try {
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
