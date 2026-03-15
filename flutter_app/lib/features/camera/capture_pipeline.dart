import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img_lib;
import '../../models/camera_definition.dart';
import '../../models/watermark_styles.dart';
import 'preview_renderer.dart';

/// 捕获后处理管线
/// 顺序：比例裁剪 → 抖动模糊 → 颜色效果 → 暗角 → 漏光 → 相框纹理PNG → 水印 → 输出 JPEG
/// 注意：水印必须在相框纹理之后绘制，否则会被相框遮挡
///
/// 性能优化（v2）：
///  1. 解码时限制最大边长 2048px（instantiateImageCodec targetWidth/targetHeight）
///  2. 输出画布最大边长 2048px（超出则等比缩放）
///  3. _drawFilmGrain 改用 Path 批量绘制，减少 draw call
///  4. 最终编码改用 JPEG（quality=92），比 PNG 快 5-10x
class CapturePipeline {
  final CameraDefinition camera;

  /// 输出图像最大边长（像素）。超过此值时等比缩小画布。
  /// 各清晰度档位的输出最大边长（像素）
  static const int kMaxDimLow    = 1920; // 低画质：1920p 长边，~2MP
  static const int kMaxDimMid    = 2688; // 中画质：2688p 长边，~4MP
  static const int kMaxDimHigh   = 4096; // 高画质：4K 长边，~12MP
  /// 各清晰度档位的 JPEG 编码质量
  static const int kJpegQualityLow  = 72; // 对齐竞品低画质 ~385 KB
  static const int kJpegQualityMid  = 80; // 对齐竞品中画质 ~442 KB
  static const int kJpegQualityHigh = 90;

  CapturePipeline({required this.camera});

  /// 处理拍摄的图片文件，返回处理后的 JPEG 字节
  Future<Uint8List?> process({
    required String imagePath,
    required String selectedRatioId,
    required String selectedFrameId,
    required String selectedWatermarkId,
    String? frameBackgroundColor, // 用户选择的背景色（覆盖 JSON 默认值）
    String? watermarkColorOverride,   // 用户覆盖颜色
    String? watermarkPositionOverride, // 用户覆盖位置
    String? watermarkSizeOverride,    // 用户覆盖大小
    String? watermarkDirectionOverride, // 用户覆盖方向
    String? watermarkStyleOverride,   // 用户覆盖样式 ID
    PreviewRenderParams? renderParams,
    Rect? minimapNormalizedRect, // 小窗模式裁剪区域（归一化 0.0~1.0）
    int deviceQuarter = 0, // 设备方向：0=竖屏, 1=逆时针横屏(左转90°), 2=倒竖, 3=顺时针横屏(右转90°)
    int maxDimension = kMaxDimMid,   // 输出最大边长（由调用方按清晰度档位传入）
    int jpegQuality  = kJpegQualityMid, // JPEG 编码质量（由调用方按清晰度档位传入）
  }) async {
    try {
          // ── 1. 读取原始图片（解码时限制最大边长，避免 12MP 全量解码）──────────────
      final bytes = await File(imagePath).readAsBytes();
      // 通过 JPEG 文件头解析原始尺寸（避免两次全量解码）
      final rawSize = _readJpegDimensions(bytes);
      final rawW = rawSize?[0] ?? 0;
      final rawH = rawSize?[1] ?? 0;

      // 计算解码目标尺寸（限制最大边长为 maxDimension）
      final maxRaw = math.max(rawW, rawH);
      int? decodeTargetW;
      int? decodeTargetH;
      if (maxRaw > maxDimension && maxRaw > 0) {
        final scale = maxDimension / maxRaw;
        decodeTargetW = (rawW * scale).round();
        decodeTargetH = (rawH * scale).round();
      }

      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: decodeTargetW,
        targetHeight: decodeTargetH,
      );
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;

      final srcW = srcImage.width.toDouble();
      final srcH = srcImage.height.toDouble();

      debugPrint('[CapturePipeline] src: ${rawW}x${rawH} → decoded: ${srcW.toInt()}x${srcH.toInt()}, ratio=$selectedRatioId, frame=$selectedFrameId, wm=$selectedWatermarkId');

      // ── 2. 计算裁剪区域（保持中心裁剪）────────────────────────────────────────────
      Rect cropRect = _calcCropRect(srcW, srcH, selectedRatioId);
      // ── 2b. 小窗模式：将裁剪区域进一步缩小到小窗内容 ──────────────────────────────
      if (minimapNormalizedRect != null) {
        final mmLeft   = cropRect.left   + minimapNormalizedRect.left   * cropRect.width;
        final mmTop    = cropRect.top    + minimapNormalizedRect.top    * cropRect.height;
        final mmRight  = cropRect.left   + minimapNormalizedRect.right  * cropRect.width;
        final mmBottom = cropRect.top    + minimapNormalizedRect.bottom * cropRect.height;
        cropRect = Rect.fromLTRB(mmLeft, mmTop, mmRight, mmBottom);
        debugPrint('[CapturePipeline] minimap crop: ${cropRect.width}x${cropRect.height}@(${cropRect.left},${cropRect.top})');
      }
      double outW = cropRect.width;
      double outH = cropRect.height;

      debugPrint('[CapturePipeline] crop: ${outW}x${outH}');

      // ── 3. 边框 inset 计算（在裁剪后尺寸上扩展画布）──────────────────────────
      double topPx = 0, rightPx = 0, bottomPx = 0, leftPx = 0;
      FrameDefinition? frameOpt;
      if (selectedFrameId.isNotEmpty &&
          selectedFrameId != 'frame_none' &&
          selectedFrameId != 'none') {
        try {
          frameOpt = camera.modules.frames.firstWhere((f) => f.id == selectedFrameId);
          final refSize = math.min(outW, outH);
          final scale = refSize / 1080.0;
          final activeInset = frameOpt.insetForRatio(selectedRatioId);
          topPx = activeInset.top * scale;
          rightPx = activeInset.right * scale;
          bottomPx = activeInset.bottom * scale;
          leftPx = activeInset.left * scale;
          debugPrint('[CapturePipeline] frame inset (ratio=$selectedRatioId): t=$topPx r=$rightPx b=$bottomPx l=$leftPx');
        } catch (_) {
          frameOpt = null;
        }
      }

      // ── 3b. 外层背景间距计算 ────────────────────────────────────────────────────
      double outerPadPx = 0;
      if (frameOpt != null && frameOpt.outerPadding > 0) {
        final refSize = math.min(outW, outH);
        final scale = refSize / 1080.0;
        outerPadPx = frameOpt.outerPadding * scale;
      }

      // 相框层画布尺寸 = 裁剪尺寸 + 边框 inset
      final frameCanvasW = outW + leftPx + rightPx;
      final frameCanvasH = outH + topPx + bottomPx;

      final resolvedAsset = frameOpt?.assetForRatio(selectedRatioId);
      final hasPngAssetForSize = selectedFrameId.isNotEmpty &&
          selectedFrameId != 'frame_none' &&
          selectedFrameId != 'none' &&
          frameOpt != null &&
          resolvedAsset != null &&
          resolvedAsset.isNotEmpty;

      // 最终输出画布尺寸（含 outerPadding）
      double canvasW = hasPngAssetForSize ? frameCanvasW : frameCanvasW + outerPadPx * 2;
      double canvasH = hasPngAssetForSize ? frameCanvasH : frameCanvasH + outerPadPx * 2;

      // ── 3c. 限制画布最大边长（防止超大画布导致 GPU OOM / 卡顿）─────────────────────
      final maxCanvas = math.max(canvasW, canvasH);
      double canvasScale = 1.0;
      if (maxCanvas > maxDimension) {
        canvasScale = maxDimension / maxCanvas;
        canvasW *= canvasScale;
        canvasH *= canvasScale;
        outW *= canvasScale;
        outH *= canvasScale;
        topPx *= canvasScale;
        rightPx *= canvasScale;
        bottomPx *= canvasScale;
        leftPx *= canvasScale;
        outerPadPx *= canvasScale;
        debugPrint('[CapturePipeline] canvas downscaled by $canvasScale → ${canvasW.toInt()}x${canvasH.toInt()}');
      }

      final frameOffsetX = hasPngAssetForSize ? 0.0 : outerPadPx;
      final frameOffsetY = hasPngAssetForSize ? 0.0 : outerPadPx;

      // ── 4. 创建画布 ──────────────────────────────────────────────────────────
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, canvasW, canvasH));

      // ── 4a. 先填充画布背景色 ────────────────────────────────────────────────────
      {
        String bgHexSrc = '#FFFFFF';
        if (frameOpt != null) {
          bgHexSrc = (frameBackgroundColor != null && frameBackgroundColor.isNotEmpty)
              ? frameBackgroundColor
              : frameOpt.outerBackgroundColor;
        } else if (frameBackgroundColor != null && frameBackgroundColor.isNotEmpty) {
          bgHexSrc = frameBackgroundColor;
        }
        if (bgHexSrc.toLowerCase() != 'transparent' && bgHexSrc.toLowerCase() != '#00000000') {
          Color bgColor = Colors.white;
          try {
            final hex = bgHexSrc.replaceAll('#', '');
            bgColor = Color(int.parse('FF$hex', radix: 16));
          } catch (_) {}
          canvas.drawRect(
            Rect.fromLTWH(0, 0, canvasW, canvasH),
            Paint()..color = bgColor,
          );
        }
      }

      // ── 4b. 填充相框背景色（无 PNG 边框时）────────────────────────────────────────
      if (frameOpt != null && !hasPngAssetForSize) {
        Color bgColor = const Color(0xFFF5F2EA);
        final bgHexSrc = (frameBackgroundColor != null && frameBackgroundColor.isNotEmpty)
            ? frameBackgroundColor
            : frameOpt.backgroundColor;
        try {
          if (bgHexSrc.toLowerCase() == 'transparent') {
            bgColor = Colors.transparent;
          } else {
            final hex = bgHexSrc.replaceAll('#', '');
            bgColor = Color(int.parse('FF$hex', radix: 16));
          }
        } catch (_) {}
        if (bgColor != Colors.transparent) {
          final refSize = math.min(outW, outH);
          final frameScale = refSize / 1080.0;
          final cornerRadiusPx = frameOpt.cornerRadius * frameScale;
          if (cornerRadiusPx > 0) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(frameOffsetX, frameOffsetY, outW + leftPx + rightPx, outH + topPx + bottomPx),
                Radius.circular(cornerRadiusPx),
              ),
              Paint()..color = bgColor,
            );
          } else {
            canvas.drawRect(
              Rect.fromLTWH(frameOffsetX, frameOffsetY, outW + leftPx + rightPx, outH + topPx + bottomPx),
              Paint()..color = bgColor,
            );
          }
        }
      }

      // ── 4b. 绘制图片（抖动模糊 + 颜色效果）────────────────────────────────────
      final destRect = Rect.fromLTWH(frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH);
      final shakeStrength = frameOpt?.shake ?? 0.0;

      if (shakeStrength > 0.01) {
        final rng = math.Random(DateTime.now().millisecondsSinceEpoch);
        final maxOffset = outW * 0.015 * shakeStrength;
        final dx1 = (rng.nextDouble() - 0.5) * 2 * maxOffset;
        final dy1 = (rng.nextDouble() - 0.5) * 2 * maxOffset;
        final dx2 = (rng.nextDouble() - 0.5) * 2 * maxOffset * 0.6;
        final dy2 = (rng.nextDouble() - 0.5) * 2 * maxOffset * 0.6;
        final ghostAlpha1 = (shakeStrength * 55).clamp(0, 55).toInt();
        final ghostAlpha2 = (shakeStrength * 35).clamp(0, 35).toInt();
        final shakeRect1 = Rect.fromLTWH(frameOffsetX + leftPx + dx1, frameOffsetY + topPx + dy1, outW, outH);
        final shakeRect2 = Rect.fromLTWH(frameOffsetX + leftPx + dx2, frameOffsetY + topPx + dy2, outW, outH);

        if (renderParams != null) {
          final colorMatrix = _buildColorMatrix(renderParams);
          canvas.drawImageRect(srcImage, cropRect, shakeRect1,
            Paint()
              ..filterQuality = FilterQuality.medium
              ..colorFilter = ColorFilter.matrix(colorMatrix)
              ..color = Colors.white.withAlpha(ghostAlpha1),
          );
          canvas.drawImageRect(srcImage, cropRect, shakeRect2,
            Paint()
              ..filterQuality = FilterQuality.medium
              ..colorFilter = ColorFilter.matrix(colorMatrix)
              ..color = Colors.white.withAlpha(ghostAlpha2),
          );
        } else {
          canvas.drawImageRect(srcImage, cropRect, shakeRect1,
            Paint()..filterQuality = FilterQuality.medium..color = Colors.white.withAlpha(ghostAlpha1));
          canvas.drawImageRect(srcImage, cropRect, shakeRect2,
            Paint()..filterQuality = FilterQuality.medium..color = Colors.white.withAlpha(ghostAlpha2));
        }
      }

      // 主图（正常绘制）
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

      // ── 4c. 暗角 ──────────────────────────────────────────────────────────────
      if (renderParams != null && renderParams.effectiveVignette > 0.01) {
        _drawVignette(canvas, frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH, renderParams.effectiveVignette);
      }

      // ── 4c3. 胶片颗粒感（grain）──────────────────────────────────────────────
      if (renderParams != null && renderParams.effectiveGrain > 0.01) {
        _drawFilmGrain(canvas, frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH, renderParams.effectiveGrain);
      }

      // ── 4c2. 内嵌阴影（拟物相纸厚度感）──────────────────────────────────────
      if (frameOpt != null && frameOpt.innerShadow) {
        _drawInnerShadow(canvas, frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH);
      }

      // ── 4d. 漏光效果 ──────────────────────────────────────────────────────────
      final lightLeakStrength = frameOpt?.lightLeak ?? 0.0;
      if (lightLeakStrength > 0.01) {
        _drawLightLeak(canvas, frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH, lightLeakStrength);
      }

      // ── 4f. 相框纹理 PNG 叠加 ──────────────────────────────────────────────────
      if (frameOpt != null && resolvedAsset != null && resolvedAsset.isNotEmpty) {
        try {
          final assetData = await rootBundle.load(resolvedAsset);
          final frameCodec = await ui.instantiateImageCodec(
            assetData.buffer.asUint8List(),
            targetWidth: canvasW.toInt(),
            targetHeight: canvasH.toInt(),
          );
          final frameImgFrame = await frameCodec.getNextFrame();
          canvas.drawImageRect(
            frameImgFrame.image,
            Rect.fromLTWH(0, 0,
              frameImgFrame.image.width.toDouble(),
              frameImgFrame.image.height.toDouble()),
            Rect.fromLTWH(0, 0, canvasW, canvasH),
            Paint()..filterQuality = FilterQuality.high,
          );
          debugPrint('[CapturePipeline] frame texture applied: $resolvedAsset (ratio=$selectedRatioId)');
        } catch (e) {
          debugPrint('[CapturePipeline] frame asset load error: $e');
        }
      }

      // ── 4g. 水印 ──────────────────────────────────────────────────────────────
      if (selectedWatermarkId.isNotEmpty && selectedWatermarkId != 'none') {
        _drawWatermark(
          canvas,
          frameOffsetX + leftPx,
          frameOffsetY + topPx,
          outW,
          outH,
          selectedWatermarkId,
          colorOverride: watermarkColorOverride,
          positionOverride: watermarkPositionOverride,
          sizeOverride: watermarkSizeOverride,
          directionOverride: watermarkDirectionOverride,
          styleOverride: watermarkStyleOverride,
        );
      }

      // ── 5. 光栅化并输出 ────────────────────────────────────────────────────────
      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(canvasW.toInt(), canvasH.toInt());

      // ── 5b. 根据设备方向旋转图片 ──────────────────────────────────────────────
      ui.Image finalImage = outputImage;
      if (deviceQuarter != 0) {
        final rotAngle = deviceQuarter * math.pi / 2;
        final isLandscape = deviceQuarter == 1 || deviceQuarter == 3;
        final rotW = isLandscape ? canvasH : canvasW;
        final rotH = isLandscape ? canvasW : canvasH;
        final rotRecorder = ui.PictureRecorder();
        final rotCanvas = Canvas(rotRecorder, Rect.fromLTWH(0, 0, rotW, rotH));
        rotCanvas.translate(rotW / 2, rotH / 2);
        rotCanvas.rotate(rotAngle);
        rotCanvas.translate(-canvasW / 2, -canvasH / 2);
        rotCanvas.drawImage(outputImage, Offset.zero, Paint());
        final rotPicture = rotRecorder.endRecording();
        finalImage = await rotPicture.toImage(rotW.toInt(), rotH.toInt());
        debugPrint('[CapturePipeline] rotated: quarter=$deviceQuarter, ${rotW.toInt()}x${rotH.toInt()}');
      }      // ── 5c. 编码为 JPEG（比 PNG 快 5-10x，quality=92 视觉无损）──────────────────
      final byteData = await finalImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;

      final finalW = deviceQuarter == 1 || deviceQuarter == 3 ? canvasH.toInt() : canvasW.toInt();
      final finalH = deviceQuarter == 1 || deviceQuarter == 3 ? canvasW.toInt() : canvasH.toInt();

      final jpegBytes = await _encodeJpeg(
        byteData.buffer.asUint8List(),
        finalW,
        finalH,
        quality: jpegQuality,
      );
      debugPrint('[CapturePipeline] output: ${finalW}x${finalH}, bytes=${jpegBytes.length}');
      return jpegBytes;
    } catch (e, st) {
      debugPrint('[CapturePipeline] Error: $e\n$st');
      return null;
    }
  }

  // ── 比例裁剪（中心裁剪，保持目标宽高比）────────────────────────────────────────

  Rect _calcCropRect(double w, double h, String ratioId) {
    RatioDefinition? ratioOpt;
    if (ratioId.isNotEmpty) {
      try {
        ratioOpt = camera.modules.ratios.firstWhere((r) => r.id == ratioId);
      } catch (_) {}
    }
    ratioOpt ??= camera.modules.ratios.isNotEmpty ? camera.modules.ratios.first : null;

    if (ratioOpt == null) return Rect.fromLTWH(0, 0, w, h);

    final targetRatio = ratioOpt.width.toDouble() / ratioOpt.height.toDouble();
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

    debugPrint('[CapturePipeline] ratio=${ratioOpt.label} targetRatio=$targetRatio srcRatio=$srcRatio crop=${cropW}x${cropH}@($cropX,$cropY)');
    return Rect.fromLTWH(cropX, cropY, cropW, cropH);
  }

  // ── 颜色矩阵（与预览一致）────────────────────────────────────────────────────

  List<double> _buildColorMatrix(PreviewRenderParams params) {
    var m = _identity();

    // 1. 曝光
    final expMul = math.pow(2.0, params.exposureOffset).toDouble();
    m = _multiply(m, _exposureMatrix(expMul));
    // 2. 色温
    if (params.policy.enableTemperature) {
      m = _multiply(m, _temperatureMatrix(params.effectiveTemperature));
    }
    // 3. 色调 (tint: green/magenta)
    if (params.policy.enableTemperature && params.effectiveTint.abs() > 0.5) {
      m = _multiply(m, _tintMatrix(params.effectiveTint));
    }
    // 4. 黑场/白场
    if (params.policy.enableContrast) {
      if (params.effectiveBlacks.abs() > 0.5 || params.effectiveWhites.abs() > 0.5) {
        m = _multiply(m, _blacksWhitesMatrix(params.effectiveBlacks, params.effectiveWhites));
      }
    }
    // 5. 对比度
    if (params.policy.enableContrast) {
      m = _multiply(m, _contrastMatrix(params.effectiveContrast));
    }
    // 6. 高光/阴影
    if (params.policy.enableContrast) {
      if (params.effectiveHighlights.abs() > 0.5 || params.effectiveShadows.abs() > 0.5) {
        m = _multiply(m, _highlightsShadowsMatrix(
          params.effectiveHighlights, params.effectiveShadows));
      }
    }
    // 7. 清晰度 (clarity)
    if (params.policy.enableContrast && params.effectiveClarity.abs() > 0.5) {
      m = _multiply(m, _clarityMatrix(params.effectiveClarity));
    }
    // 8. 饱和度
    if (params.policy.enableSaturation) {
      m = _multiply(m, _saturationMatrix(params.effectiveSaturation));
    }
    // 9. 自然饱和度 (vibrance)
    if (params.policy.enableSaturation && params.effectiveVibrance.abs() > 0.5) {
      m = _multiply(m, _vibranceMatrix(params.effectiveVibrance));
    }
    // 10. 色彩偏移 (film color bias)
    if (params.effectiveColorBiasR.abs() > 0.005 ||
        params.effectiveColorBiasG.abs() > 0.005 ||
        params.effectiveColorBiasB.abs() > 0.005) {
      m = _multiply(m, _colorBiasMatrix(
        params.effectiveColorBiasR,
        params.effectiveColorBiasG,
        params.effectiveColorBiasB,
      ));
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
    final rShift = t * 0.20;
    final bShift = -t * 0.20;
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

  List<double> _tintMatrix(double tint) {
    final t = tint / 100.0;
    final gShift = -t * 0.12;
    final rbShift = t * 0.06;
    return [
      1 + rbShift, 0, 0, 0, 0,
      0, 1 + gShift, 0, 0, 0,
      0, 0, 1 + rbShift, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _blacksWhitesMatrix(double blacks, double whites) {
    final blacksOffset = blacks / 100.0 * 20.0;
    final whitesScale = 1.0 + whites / 100.0 * 0.15;
    return [
      whitesScale, 0, 0, 0, blacksOffset,
      0, whitesScale, 0, 0, blacksOffset,
      0, 0, whitesScale, 0, blacksOffset,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _highlightsShadowsMatrix(double highlights, double shadows) {
    final hScale = 1.0 + highlights / 100.0 * 0.12;
    final hOffset = -highlights / 100.0 * 0.12 * 191.0;
    final sScale = 1.0 - shadows / 100.0 * 0.08;
    final sOffset = shadows / 100.0 * 0.08 * 64.0 + shadows / 100.0 * 12.0;
    final scale = hScale * sScale;
    final offset = hOffset * sScale + sOffset;
    return [
      scale, 0, 0, 0, offset,
      0, scale, 0, 0, offset,
      0, 0, scale, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _clarityMatrix(double clarity) {
    final c = clarity / 100.0;
    final boost = 1.0 + c * 0.15;
    final offset = -c * 0.15 * 0.5 * 255;
    return [
      boost, 0, 0, 0, offset,
      0, boost, 0, 0, offset,
      0, 0, boost, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _vibranceMatrix(double vibrance) {
    final v = vibrance / 100.0 * 0.6;
    final sat = 1.0 + v;
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

  List<double> _colorBiasMatrix(double r, double g, double b) {
    return [
      1, 0, 0, 0, r * 30.0,
      0, 1, 0, 0, g * 30.0,
      0, 0, 1, 0, b * 30.0,
      0, 0, 0, 1, 0,
    ];
  }

  // ── 暗角（绘制在图片区域内）──────────────────────────────────────────────────

  /// 内嵌阴影：在图片区域四边绘制渐变阴影，模拟相纸内凹厚度感
  void _drawInnerShadow(
      Canvas canvas, double ox, double oy, double w, double h) {
    const shadowColor = Color(0x55000000);
    const shadowWidth = 0.06;
    final sw = math.min(w, h) * shadowWidth;
    canvas.drawRect(
      Rect.fromLTWH(ox, oy, w, sw),
      Paint()..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [shadowColor, Colors.transparent],
      ).createShader(Rect.fromLTWH(ox, oy, w, sw)),
    );
    canvas.drawRect(
      Rect.fromLTWH(ox, oy + h - sw, w, sw),
      Paint()..shader = LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [shadowColor, Colors.transparent],
      ).createShader(Rect.fromLTWH(ox, oy + h - sw, w, sw)),
    );
    canvas.drawRect(
      Rect.fromLTWH(ox, oy, sw, h),
      Paint()..shader = LinearGradient(
        begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: [shadowColor, Colors.transparent],
      ).createShader(Rect.fromLTWH(ox, oy, sw, h)),
    );
    canvas.drawRect(
      Rect.fromLTWH(ox + w - sw, oy, sw, h),
      Paint()..shader = LinearGradient(
        begin: Alignment.centerRight, end: Alignment.centerLeft,
        colors: [shadowColor, Colors.transparent],
      ).createShader(Rect.fromLTWH(ox + w - sw, oy, sw, h)),
    );
  }

  // ── 胶片颗粒感（Film Grain）────────────────────────────────────────────────
  /// 优化版：使用两个 Path（亮颗粒 / 暗颗粒）批量绘制，减少 draw call 从 O(N) 降到 O(2)
  void _drawFilmGrain(
      Canvas canvas, double ox, double oy, double w, double h, double strength) {
    final rng = math.Random(12345);
    // 颗粒数量限制在 2000 以内（原来最多 8000），视觉效果几乎无差异
    final count = (w * h * strength * 0.004).clamp(100, 2000).toInt();
    final baseSize = (strength * 2.5).clamp(0.5, 3.0);
    final alpha = (strength * 120).clamp(30, 140).toInt();

    // 亮颗粒 Path（overlay 模式）
    final brightPath = Path();
    // 暗颗粒 Path（overlay 模式）
    final darkPath = Path();

    for (int i = 0; i < count; i++) {
      final px = ox + rng.nextDouble() * w;
      final py = oy + rng.nextDouble() * h;
      final size = baseSize * (0.5 + rng.nextDouble() * 0.8);
      if (rng.nextBool()) {
        brightPath.addOval(Rect.fromCircle(center: Offset(px, py), radius: size));
      } else {
        darkPath.addOval(Rect.fromCircle(center: Offset(px, py), radius: size));
      }
    }

    final brightness = (strength * 60).clamp(20, 80).toInt();
    canvas.drawPath(
      brightPath,
      Paint()
        ..color = Color.fromARGB(alpha, brightness, brightness, brightness)
        ..blendMode = BlendMode.overlay,
    );
    canvas.drawPath(
      darkPath,
      Paint()
        ..color = Color.fromARGB(alpha, 0, 0, 0)
        ..blendMode = BlendMode.overlay,
    );
  }

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

  // ── 漏光效果（角落径向渐变，暖橙/红色）─────────────────────────────────────────

  void _drawLightLeak(
      Canvas canvas, double ox, double oy, double w, double h, double strength) {
    final rng = math.Random(42);
    final corners = [
      Offset(ox, oy),
      Offset(ox + w, oy),
      Offset(ox, oy + h),
      Offset(ox + w, oy + h),
    ];
    final selectedCorners = [corners[rng.nextInt(4)]];
    if (strength > 0.5) {
      int idx2;
      do { idx2 = rng.nextInt(4); } while (corners[idx2] == selectedCorners[0]);
      selectedCorners.add(corners[idx2]);
    }

    for (final corner in selectedCorners) {
      final radius = math.max(w, h) * 0.65 * strength;
      final leakColor = Color.fromARGB(
        (strength * 90).clamp(0, 90).toInt(),
        255,
        rng.nextInt(60) + 80,
        20,
      );
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [leakColor, Colors.transparent],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: corner, radius: radius));
      canvas.drawRect(Rect.fromLTWH(ox, oy, w, h), paint);
    }
  }

  // ── 水印（绘制在图片区域内）──────────────────────────────────────────────────

  void _drawWatermark(
      Canvas canvas, double ox, double oy, double w, double h, String watermarkId, {
    String? colorOverride,
    String? positionOverride,
    String? sizeOverride,
    String? directionOverride,
    String? styleOverride,
  }) {
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
    final styleDef = getWatermarkStyle(styleOverride);
    final text = styleDef.buildText(now);

    Color textColor = const Color(0xFFFF8C00);
    final colorSrc = colorOverride ?? wmOpt.color;
    if (colorSrc != null && colorSrc.isNotEmpty) {
      try {
        final hex = colorSrc.replaceAll('#', '');
        textColor = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }

    double baseFontSize;
    switch (sizeOverride) {
      case 'small':  baseFontSize = w * 0.028; break;
      case 'medium': baseFontSize = w * 0.038; break;
      case 'large':  baseFontSize = w * 0.055; break;
      default:
        baseFontSize = w * 0.038;
    }
    final fontSize = baseFontSize.clamp(12.0, 120.0);

    final isVertical = (directionOverride ?? 'horizontal') == 'vertical';
    final position = positionOverride ?? wmOpt.position ?? 'bottom_right';
    final margin = w * 0.04;

    final fontFamily = styleDef.fontFamily ?? wmOpt.fontFamily;
    final letterSpacing = styleDef.letterSpacing;
    final fontWeight = styleDef.fontWeight;

    if (isVertical) {
      final charPainters = text.split('').map((c) {
        final p = TextPainter(
          text: TextSpan(text: c, style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontWeight: fontWeight,
          )),
          textDirection: TextDirection.ltr,
        )..layout();
        return p;
      }).toList();

      final totalH = charPainters.fold(0.0, (s, p) => s + p.height);
      final charW = charPainters.fold(0.0, (s, p) => math.max(s, p.width));

      double startX, startY;
      switch (position) {
        case 'bottom_right':
          startX = ox + w - charW - margin;
          startY = oy + h - totalH - margin;
          break;
        case 'bottom_left':
          startX = ox + margin;
          startY = oy + h - totalH - margin;
          break;
        case 'top_right':
          startX = ox + w - charW - margin;
          startY = oy + margin;
          break;
        case 'top_left':
          startX = ox + margin;
          startY = oy + margin;
          break;
        case 'bottom_center':
          startX = ox + (w - charW) / 2;
          startY = oy + h - totalH - margin;
          break;
        case 'top_center':
          startX = ox + (w - charW) / 2;
          startY = oy + margin;
          break;
        default:
          startX = ox + w - charW - margin;
          startY = oy + h - totalH - margin;
      }

      double curY = startY;
      for (final p in charPainters) {
        p.paint(canvas, Offset(startX + (charW - p.width) / 2, curY));
        curY += p.height;
      }
    } else {
      final textPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontWeight: fontWeight,
            letterSpacing: letterSpacing,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w);

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
        case 'bottom_center':
          dx = ox + (w - textPainter.width) / 2;
          dy = oy + h - textPainter.height - margin;
          break;
        case 'top_center':
          dx = ox + (w - textPainter.width) / 2;
          dy = oy + margin;
          break;
        default:
          dx = ox + w - textPainter.width - margin;
          dy = oy + h - textPainter.height - margin;
      }

      textPainter.paint(canvas, Offset(dx, dy));
    }
  }

  // ── JPEG 文件头解析（不需全量解码）────────────────────────────────────
  /// 解析 JPEG SOF 段获取图片尺寸，返回 [width, height]。失败返回 null。
  List<int>? _readJpegDimensions(Uint8List bytes) {
    try {
      int i = 0;
      if (bytes.length < 4) return null;
      // JPEG SOI marker: FF D8
      if (bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
      i = 2;
      while (i < bytes.length - 1) {
        if (bytes[i] != 0xFF) return null;
        final marker = bytes[i + 1];
        i += 2;
        // SOF markers: C0-C3, C5-C7, C9-CB, CD-CF
        if ((marker >= 0xC0 && marker <= 0xC3) ||
            (marker >= 0xC5 && marker <= 0xC7) ||
            (marker >= 0xC9 && marker <= 0xCB) ||
            (marker >= 0xCD && marker <= 0xCF)) {
          // SOF segment: length(2) + precision(1) + height(2) + width(2)
          if (i + 7 > bytes.length) return null;
          final h = (bytes[i + 3] << 8) | bytes[i + 4];
          final w = (bytes[i + 5] << 8) | bytes[i + 6];
          return [w, h];
        }
        // Skip segment
        if (i + 1 >= bytes.length) return null;
        final segLen = (bytes[i] << 8) | bytes[i + 1];
        i += segLen;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── RGBA bytes → JPEG bytes（使用 compute() 在独立 Isolate 中编码，不阻塞 UI 线程）─────────
  Future<Uint8List> _encodeJpeg(Uint8List rgba, int w, int h, {int quality = 82}) {
    return compute(_encodeJpegIsolate, _JpegEncodeParams(rgba, w, h, quality));
  }
}
// ── Isolate 顶层函数（必须是顶层函数，不能是类方法）────────────────────────────────────
class _JpegEncodeParams {
  final Uint8List rgba;
  final int w;
  final int h;
  final int quality;
  const _JpegEncodeParams(this.rgba, this.w, this.h, this.quality);
}

Uint8List _encodeJpegIsolate(_JpegEncodeParams p) {
  final image = img_lib.Image.fromBytes(
    width: p.w,
    height: p.h,
    bytes: p.rgba.buffer,
    format: img_lib.Format.uint8,
    numChannels: 4,
  );
  final jpegBytes = img_lib.encodeJpg(image, quality: p.quality);
  return Uint8List.fromList(jpegBytes);
}
