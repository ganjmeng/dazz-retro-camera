import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'capture_pipeline_ext.dart';
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
/// 拍照处理结果，包含 JPEG 字节和输出分辨率
class CaptureResult {
  final Uint8List bytes;
  final int outputWidth;
  final int outputHeight;
  const CaptureResult(
      {required this.bytes,
      required this.outputWidth,
      required this.outputHeight});
}

class CapturePipeline {
  final CameraDefinition camera;
  static const int _kFrameTextureCacheMaxEntries = 6;
  static final Map<String, ui.Image> _frameTextureCache = <String, ui.Image>{};
  static final List<String> _frameTextureLru = <String>[];
  static const int _kFrameAssetBytesCacheMaxEntries = 8;
  static final Map<String, Uint8List> _frameAssetBytesCache =
      <String, Uint8List>{};
  static final List<String> _frameAssetBytesLru = <String>[];

  /// 输出图像最大边长（像素）。超过此値时等比缩小画布。
  /// 各清晰度档位的输出最大边长（像素）
  static const int kMaxDimLow = 1920; // 低画质：1920p 长边，~2MP
  static const int kMaxDimMid =
      1920; // 中画质：1920p 长边，与低档对齐（减少 glReadPixels 回读量 ~50%）
  static const int kMaxDimHigh = 4096; // 高画质：4K 长边，~12MP
  /// 各清晰度档位的 JPEG 编码质量
  static const int kJpegQualityLow = 72; // 对齐竞品低画质 ~385 KB
  static const int kJpegQualityMid = 80; // 对齐竞品中画质 ~442 KB
  static const int kJpegQualityHigh = 90;

  CapturePipeline({required this.camera});

  Future<Uint8List> _getFrameAssetBytes(String assetPath) async {
    final cached = _frameAssetBytesCache[assetPath];
    if (cached != null) {
      _frameAssetBytesLru.remove(assetPath);
      _frameAssetBytesLru.add(assetPath);
      return cached;
    }
    final assetData = await rootBundle.load(assetPath);
    final bytes = assetData.buffer.asUint8List();
    _frameAssetBytesCache[assetPath] = bytes;
    _frameAssetBytesLru.remove(assetPath);
    _frameAssetBytesLru.add(assetPath);
    while (_frameAssetBytesLru.length > _kFrameAssetBytesCacheMaxEntries) {
      final evictKey = _frameAssetBytesLru.removeAt(0);
      _frameAssetBytesCache.remove(evictKey);
    }
    return bytes;
  }

  Future<ui.Image> _getFrameTexture(
      String assetPath, int targetWidth, int targetHeight) async {
    final key = '$assetPath@$targetWidth@$targetHeight';
    final cached = _frameTextureCache[key];
    if (cached != null) {
      _frameTextureLru.remove(key);
      _frameTextureLru.add(key);
      return cached;
    }
    final assetBytes = await _getFrameAssetBytes(assetPath);
    final frameCodec = await ui.instantiateImageCodec(
      assetBytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await frameCodec.getNextFrame();
    _frameTextureCache[key] = frame.image;
    _frameTextureLru.remove(key);
    _frameTextureLru.add(key);
    while (_frameTextureLru.length > _kFrameTextureCacheMaxEntries) {
      final evictKey = _frameTextureLru.removeAt(0);
      _frameTextureCache.remove(evictKey);
    }
    return frame.image;
  }

  /// 处理拍摄的图片文件，返回包含 JPEG 字节和输出分辨率的 CaptureResult
  static const MethodChannel _channel =
      MethodChannel("com.retrocam.app/camera_control");

  Future<CaptureResult?> process({
    bool useGpu = true, // 新增开关
    required String imagePath,
    required String selectedRatioId,
    required String selectedFrameId,
    required String selectedWatermarkId,
    String? frameBackgroundColor, // 用户选择的背景色（覆盖 JSON 默认值）
    String? watermarkColorOverride, // 用户覆盖颜色
    String? watermarkPositionOverride, // 用户覆盖位置
    String? watermarkSizeOverride, // 用户覆盖大小
    String? watermarkDirectionOverride, // 用户覆盖方向
    String? watermarkStyleOverride, // 用户覆盖样式 ID
    PreviewRenderParams? renderParams,
    Rect? minimapNormalizedRect, // 小窗模式裁剪区域（归一化 0.0~1.0）
    int deviceQuarter = 0, // 设备方向：0=竖屏, 1=逆时针横屏(左转90°), 2=倒竖, 3=顺时针横屏(右转90°)
    int maxDimension = kMaxDimMid, // 输出最大边长（由调用方按清晰度档位传入）
    int jpegQuality = kJpegQualityMid, // JPEG 编码质量（由调用方按清晰度档位传入）
    bool fisheyeMode = false, // 鱼眼圆圈模式：在成片四角绘制默色阒罩
  }) async {
    try {
      // ── 1. 先尝试 GPU 快速路径（无相框/水印时完全跳过 Dart 解码）─────────────
      bool gpuProcessed = false;
      bool decodedWithScale = false;
      ui.Image? srcImage;
      String? gpuOutputPath;
      Uint8List? gpuOutputBytes;
      final needsDartOnlyPost = renderParams != null &&
          (renderParams.effectiveDehaze > 0.001 ||
              renderParams.hasCustomToneCurve ||
              renderParams.hasBwMixer ||
              renderParams.highlightWarmAmount > 0.001 ||
              renderParams.topBottomBias.abs() > 0.001 ||
              renderParams.leftRightBias.abs() > 0.001);

      if (useGpu && (Platform.isIOS || Platform.isAndroid)) {
        try {
          debugPrint(
              "[CapturePipeline] Attempting to use native GPU pipeline...");
          final gpuResult = await _channel.invokeMethod<Map>("processWithGpu", {
            "filePath": imagePath,
            "params": renderParams?.toJson() ?? {},
            "maxDimension": maxDimension,
            "jpegQuality": jpegQuality,
          });
          if (gpuResult != null && gpuResult["filePath"] != null) {
            final newPath = gpuResult["filePath"] as String;
            gpuOutputPath = newPath;
            // ── 快速路径：无相框、无水印、无小窗裁剪时，GPU 输出即最终成片 ──
            // 完全跳过 Dart 图像解码、Canvas 绘制、toByteData、JPEG 重编码
            final hasFrame = selectedFrameId.isNotEmpty &&
                selectedFrameId != 'frame_none' &&
                selectedFrameId != 'none';
            final hasWatermark =
                selectedWatermarkId.isNotEmpty && selectedWatermarkId != 'none';
            final hasMinimap = minimapNormalizedRect != null;
            if (!hasFrame &&
                !hasWatermark &&
                !hasMinimap &&
                !needsDartOnlyPost) {
              final gpuBytes = await File(newPath).readAsBytes();
              final gpuSize = _readJpegDimensions(gpuBytes);
              final gpuW = gpuSize?[0] ?? 0;
              final gpuH = gpuSize?[1] ?? 0;
              final fullRect =
                  Rect.fromLTWH(0, 0, gpuW.toDouble(), gpuH.toDouble());
              final ratioCropRect = _calcCropRect(
                gpuW.toDouble(),
                gpuH.toDouble(),
                selectedRatioId,
                preferLandscapeOutput: deviceQuarter == 1 || deviceQuarter == 3,
              );
              final needsRatioCrop =
                  (ratioCropRect.width - fullRect.width).abs() > 1.0 ||
                      (ratioCropRect.height - fullRect.height).abs() > 1.0;
              if (!needsRatioCrop) {
                try {
                  File(newPath).deleteSync();
                } catch (_) {}
                debugPrint(
                    '[CapturePipeline] Fast path: GPU output returned directly (ratio already matched), ${gpuW}x${gpuH}');
                return CaptureResult(
                    bytes: gpuBytes, outputWidth: gpuW, outputHeight: gpuH);
              }
              // 比例不一致时不能走“直接返回”，否则会出现取景框改了比例、成片仍是固定 9:16/16:9。
              gpuOutputBytes = gpuBytes;
              gpuProcessed = true;
              debugPrint(
                  '[CapturePipeline] Fast path bypassed: ratio crop required (${selectedRatioId}) from ${gpuW}x${gpuH}');
            } else {
              // 有相框/水印/小窗裁剪：优先尝试原生叠加路径，失败再回退 Dart Canvas
              gpuOutputBytes = await File(newPath).readAsBytes();
              gpuProcessed = true;
              debugPrint(
                  "[CapturePipeline] GPU pipeline successful, preparing native overlay path.");
            }
          }
        } catch (e) {
          debugPrint(
              "[CapturePipeline] Native GPU pipeline failed, falling back to Dart: $e");
        }
      }

      // ── 1b. GPU 未成功时才解码原始图片（Dart fallback 路径）──────────────────
      if (!gpuProcessed) {
        final bytes = await File(imagePath).readAsBytes();
        final rawSize = _readJpegDimensions(bytes);
        final rawW = rawSize?[0] ?? 0;
        final rawH = rawSize?[1] ?? 0;
        final maxRaw = math.max(rawW, rawH);
        int? decodeTargetW;
        int? decodeTargetH;
        if (maxRaw > maxDimension && maxRaw > 0) {
          final scale = maxDimension / maxRaw;
          decodeTargetW = (rawW * scale).round();
          decodeTargetH = (rawH * scale).round();
          decodedWithScale = true;
        }
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: decodeTargetW,
          targetHeight: decodeTargetH,
        );
        final frame = await codec.getNextFrame();
        srcImage = frame.image;
      }
      if (!gpuProcessed && renderParams != null) {
        debugPrint(
            '[CapturePipeline] Applying universal Dart fallback pipeline for: ${camera.id}');
        // ── 统一 Dart 降级管线（参数驱动，不再按相机 ID 路由）──────────────
        // 所有相机差异完全由 renderParams（来自 DefaultLook JSON）驱动
        // 处理顺序与 Native Shader（CaptureGLProcessor / CapturePipeline.metal）一致：
        //   1. Highlight Rolloff → 2. Sensor Non-uniformity → 3. Skin Protection
        //   → 4. Chemical Irregularity → 5. Paper Texture → 6. Development Softness
        if (renderParams.highlightRolloff > 0.001) {
          srcImage = await drawHighlightRolloff(
              srcImage!, renderParams.highlightRolloff);
        }
        if (renderParams.centerGain > 0.001 ||
            renderParams.edgeFalloff > 0.001 ||
            renderParams.topBottomBias.abs() > 0.001 ||
            renderParams.leftRightBias.abs() > 0.001) {
          srcImage = await drawSensorNonUniformity(
            srcImage!,
            renderParams.centerGain,
            renderParams.edgeFalloff,
            cornerWarmShift: renderParams.cornerWarmShift,
            topBottomBias: renderParams.topBottomBias,
            leftRightBias: renderParams.leftRightBias,
          );
        }
        if (renderParams.skinHueProtect > 0.5) {
          srcImage = await drawSkinHueProtect(
            srcImage!,
            renderParams.skinHueProtect,
            satProtect: renderParams.skinSatProtect,
            lumaSoften: renderParams.skinLumaSoften,
            redLimit: renderParams.skinRedLimit,
          );
        }
        if (renderParams.chemicalIrregularity > 0.001) {
          srcImage = await drawChemicalIrregularity(
              srcImage!, renderParams.chemicalIrregularity);
        }
        if (renderParams.paperTexture > 0.001) {
          srcImage =
              await drawPaperTexture(srcImage!, renderParams.paperTexture);
        }
        if (renderParams.developmentSoftness > 0.001) {
          srcImage = await drawDevelopmentSoftness(
              srcImage!, renderParams.developmentSoftness);
        }
        if (renderParams.effectiveDehaze > 0.001) {
          srcImage = await drawDehaze(srcImage!, renderParams.effectiveDehaze);
        }
        if (renderParams.highlightWarmAmount > 0.001) {
          srcImage = await drawHighlightWarmth(
              srcImage!, renderParams.highlightWarmAmount);
        }
        if (renderParams.hasBwMixer) {
          final mixer = renderParams.bwChannelMixer;
          srcImage = await drawBlackAndWhiteMixer(
              srcImage!, mixer[0], mixer[1], mixer[2]);
        }
        if (renderParams.hasCustomToneCurve) {
          srcImage = await drawToneCurvePoints(
            srcImage!,
            renderParams.toneCurvePoints,
            strength: renderParams.effectiveToneCurveStrength,
          );
        }
        debugPrint('[CapturePipeline] Universal fallback pipeline applied.');
      }

      // 计算源图尺寸：GPU 路径优先用 JPEG 头部解析，失败再回退解码。
      double srcW;
      double srcH;
      if (gpuProcessed && gpuOutputBytes != null) {
        final gpuSize = _readJpegDimensions(gpuOutputBytes);
        if (gpuSize != null && gpuSize[0] > 0 && gpuSize[1] > 0) {
          srcW = gpuSize[0].toDouble();
          srcH = gpuSize[1].toDouble();
        } else {
          final gpuCodec = await ui.instantiateImageCodec(gpuOutputBytes);
          final gpuFrame = await gpuCodec.getNextFrame();
          srcImage = gpuFrame.image;
          srcW = srcImage.width.toDouble();
          srcH = srcImage.height.toDouble();
        }
      } else {
        // srcImage 在非 GPU 路径必定已赋值
        srcW = srcImage!.width.toDouble();
        srcH = srcImage.height.toDouble();
      }

      debugPrint(
          '[CapturePipeline] decoded: ${srcW.toInt()}x${srcH.toInt()}, ratio=$selectedRatioId, frame=$selectedFrameId, wm=$selectedWatermarkId');

      // ── 2. 计算裁剪区域（保持中心裁剪）────────────────────────────────────────────
      Rect cropRect = _calcCropRect(
        srcW,
        srcH,
        selectedRatioId,
        preferLandscapeOutput: deviceQuarter == 1 || deviceQuarter == 3,
      );
      // ── 2b. 小窗模式：将裁剪区域进一步缩小到小窗内容 ──────────────────────────────
      if (minimapNormalizedRect != null) {
        final mmLeft =
            cropRect.left + minimapNormalizedRect.left * cropRect.width;
        final mmTop =
            cropRect.top + minimapNormalizedRect.top * cropRect.height;
        final mmRight =
            cropRect.left + minimapNormalizedRect.right * cropRect.width;
        final mmBottom =
            cropRect.top + minimapNormalizedRect.bottom * cropRect.height;
        cropRect = Rect.fromLTRB(mmLeft, mmTop, mmRight, mmBottom);
        debugPrint(
            '[CapturePipeline] minimap crop: ${cropRect.width}x${cropRect.height}@(${cropRect.left},${cropRect.top})');
      }
      double outW = cropRect.width;
      double outH = cropRect.height;
      final ratioCropOnlyNeeded = (cropRect.width - srcW).abs() > 1.0 ||
          (cropRect.height - srcH).abs() > 1.0;

      debugPrint('[CapturePipeline] crop: ${outW}x${outH}');

      // ── 3. 边框 inset 计算（在裁剪后尺寸上扩展画布）──────────────────────────
      double topPx = 0, rightPx = 0, bottomPx = 0, leftPx = 0;
      FrameDefinition? frameOpt;
      if (selectedFrameId.isNotEmpty &&
          selectedFrameId != 'frame_none' &&
          selectedFrameId != 'none') {
        try {
          frameOpt =
              camera.modules.frames.firstWhere((f) => f.id == selectedFrameId);
          // FIX: 检查相框是否支持当前 ratio（如 2:3 比例下拍立得相框不可用）
          if (frameOpt.supportedRatios.isNotEmpty &&
              !frameOpt.supportedRatios.contains(selectedRatioId)) {
            debugPrint(
                '[CapturePipeline] frame ${selectedFrameId} does not support ratio $selectedRatioId, skipping');
            frameOpt = null;
          }
          if (frameOpt == null)
            throw StateError('frame not supported for ratio');
          final refSize = math.min(outW, outH);
          final scale = refSize / 1080.0;
          final activeInset = frameOpt.insetForRatio(selectedRatioId);
          topPx = activeInset.top * scale;
          rightPx = activeInset.right * scale;
          bottomPx = activeInset.bottom * scale;
          leftPx = activeInset.left * scale;
          debugPrint(
              '[CapturePipeline] frame inset (ratio=$selectedRatioId): t=$topPx r=$rightPx b=$bottomPx l=$leftPx');
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
      Uint8List? nativeFrameAssetBytes;
      if (hasPngAssetForSize) {
        try {
          nativeFrameAssetBytes = await _getFrameAssetBytes(resolvedAsset);
        } catch (e) {
          debugPrint(
              '[CapturePipeline] frame asset bytes preload failed: $resolvedAsset, $e');
        }
      }

      // 最终输出画布尺寸（含 outerPadding）
      double canvasW =
          hasPngAssetForSize ? frameCanvasW : frameCanvasW + outerPadPx * 2;
      double canvasH =
          hasPngAssetForSize ? frameCanvasH : frameCanvasH + outerPadPx * 2;

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
        debugPrint(
            '[CapturePipeline] canvas downscaled by $canvasScale → ${canvasW.toInt()}x${canvasH.toInt()}');
      }

      final frameOffsetX = hasPngAssetForSize ? 0.0 : outerPadPx;
      final frameOffsetY = hasPngAssetForSize ? 0.0 : outerPadPx;
      final imageRectLeft = frameOffsetX + leftPx;
      final imageRectTop = frameOffsetY + topPx;

      String canvasBgHexSrc = '#FFFFFF';
      if (frameOpt != null) {
        canvasBgHexSrc =
            (frameBackgroundColor != null && frameBackgroundColor.isNotEmpty)
                ? frameBackgroundColor
                : frameOpt.outerBackgroundColor;
      } else if (frameBackgroundColor != null &&
          frameBackgroundColor.isNotEmpty) {
        canvasBgHexSrc = frameBackgroundColor;
      }
      final frameBgHexSrc = frameOpt == null
          ? '#F5F2EA'
          : ((frameBackgroundColor != null && frameBackgroundColor.isNotEmpty)
              ? frameBackgroundColor
              : frameOpt.backgroundColor);
      final frameCornerRadiusPx = frameOpt == null
          ? 0.0
          : frameOpt.cornerRadius * (math.min(outW, outH) / 1080.0);

      String watermarkText = '';
      String watermarkColorHex = '#FF8C00';
      String watermarkPosition = 'bottom_right';
      String watermarkDirection = 'horizontal';
      double watermarkFontSize = 0.0;
      String? watermarkFontFamily;
      int watermarkFontWeight = 400;
      double watermarkLetterSpacing = 0.0;
      if (selectedWatermarkId.isNotEmpty && selectedWatermarkId != 'none') {
        final wmPresets = camera.modules.watermarks.presets;
        try {
          final wmOpt =
              wmPresets.firstWhere((wm) => wm.id == selectedWatermarkId);
          if (!wmOpt.isNone) {
            final styleDef = getWatermarkStyle(watermarkStyleOverride);
            watermarkText = styleDef.buildText(DateTime.now());
            final colorSrc = watermarkColorOverride ?? wmOpt.color;
            if (colorSrc != null && colorSrc.isNotEmpty) {
              watermarkColorHex = colorSrc;
            }
            double baseFontSize;
            switch (watermarkSizeOverride) {
              case 'small':
                baseFontSize = outW * 0.028;
                break;
              case 'medium':
                baseFontSize = outW * 0.038;
                break;
              case 'large':
                baseFontSize = outW * 0.055;
                break;
              default:
                baseFontSize = outW * 0.038;
            }
            watermarkFontSize = baseFontSize.clamp(12.0, 120.0);
            watermarkPosition =
                watermarkPositionOverride ?? wmOpt.position ?? 'bottom_right';
            watermarkDirection = watermarkDirectionOverride ?? 'horizontal';
            watermarkFontFamily = styleDef.fontFamily ?? wmOpt.fontFamily;
            watermarkLetterSpacing = styleDef.letterSpacing;
            watermarkFontWeight =
                styleDef.fontWeight == FontWeight.bold ? 700 : 400;
          }
        } catch (_) {}
      }

      // 原生叠加：移动端 GPU 成片强制走原生 compose（含仅比例裁剪），避免 Dart Canvas
      // 引入色调/曝光漂移。非 GPU 场景仅在 renderParams==null 且未解码缩放时启用。
      final hasNativeOverlayNeed = frameOpt != null ||
          watermarkText.isNotEmpty ||
          minimapNormalizedRect != null ||
          ratioCropOnlyNeeded;
      final nativeComposeSourcePath = gpuProcessed
          ? gpuOutputPath
          : ((!decodedWithScale && renderParams == null) ? imagePath : null);
      if ((gpuProcessed || hasNativeOverlayNeed) &&
          nativeComposeSourcePath != null &&
          (Platform.isAndroid || Platform.isIOS)) {
        try {
          final composed = await _channel.invokeMethod<Map>("composeOverlay", {
            "filePath": nativeComposeSourcePath,
            "cropLeft": cropRect.left,
            "cropTop": cropRect.top,
            "cropWidth": cropRect.width,
            "cropHeight": cropRect.height,
            "canvasWidth": canvasW,
            "canvasHeight": canvasH,
            "imageLeft": imageRectLeft,
            "imageTop": imageRectTop,
            "imageWidth": outW,
            "imageHeight": outH,
            "frameOuterLeft": frameOffsetX,
            "frameOuterTop": frameOffsetY,
            "frameOuterWidth": outW + leftPx + rightPx,
            "frameOuterHeight": outH + topPx + bottomPx,
            "canvasBgColor": canvasBgHexSrc,
            "drawFrameBg": frameOpt != null && !hasPngAssetForSize,
            "frameBgColor": frameBgHexSrc,
            "frameCornerRadius": frameCornerRadiusPx,
            "frameAssetPath": resolvedAsset ?? "",
            "frameAssetBytes": nativeFrameAssetBytes,
            "watermarkText": watermarkText,
            "watermarkColor": watermarkColorHex,
            "watermarkPosition": watermarkPosition,
            "watermarkDirection": watermarkDirection,
            "watermarkFontSize": watermarkFontSize,
            "watermarkFontFamily": watermarkFontFamily ?? "",
            "watermarkFontWeight": watermarkFontWeight,
            "watermarkLetterSpacing": watermarkLetterSpacing,
            "watermarkHasFrame": frameOpt != null,
            "jpegQuality": jpegQuality,
          });
          final composedPath = composed?["filePath"] as String?;
          if (composedPath != null && composedPath.isNotEmpty) {
            final outBytes = await File(composedPath).readAsBytes();
            try {
              File(composedPath).deleteSync();
            } catch (_) {}
            try {
              if (gpuOutputPath != null && gpuOutputPath != composedPath) {
                File(gpuOutputPath).deleteSync();
              }
            } catch (_) {}
            return CaptureResult(
              bytes: outBytes,
              outputWidth: canvasW.toInt(),
              outputHeight: canvasH.toInt(),
            );
          }
          if (gpuProcessed) {
            final fallbackBytes = gpuOutputBytes ??
                await File(nativeComposeSourcePath).readAsBytes();
            final fallbackSize = _readJpegDimensions(fallbackBytes);
            final fw = fallbackSize?[0] ?? 0;
            final fh = fallbackSize?[1] ?? 0;
            return CaptureResult(
              bytes: fallbackBytes,
              outputWidth: fw,
              outputHeight: fh,
            );
          }
        } catch (e) {
          debugPrint('[CapturePipeline] native compose failed: $e');
          if (gpuProcessed) {
            final fallbackBytes = gpuOutputBytes ??
                await File(nativeComposeSourcePath).readAsBytes();
            final fallbackSize = _readJpegDimensions(fallbackBytes);
            final fw = fallbackSize?[0] ?? 0;
            final fh = fallbackSize?[1] ?? 0;
            return CaptureResult(
              bytes: fallbackBytes,
              outputWidth: fw,
              outputHeight: fh,
            );
          }
        }
      }

      if (gpuProcessed && srcImage == null && gpuOutputBytes != null) {
        final gpuCodec = await ui.instantiateImageCodec(gpuOutputBytes);
        final gpuFrame = await gpuCodec.getNextFrame();
        srcImage = gpuFrame.image;
      }
      final sourceImage = srcImage!;

      // ── 4. 创建画布 ──────────────────────────────────────────────────────────
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, canvasW, canvasH));

      // ── 4a. 先填充画布背景色 ────────────────────────────────────────────────────
      {
        if (canvasBgHexSrc.toLowerCase() != 'transparent' &&
            canvasBgHexSrc.toLowerCase() != '#00000000') {
          Color bgColor = Colors.white;
          try {
            final hex = canvasBgHexSrc.replaceAll('#', '');
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
        try {
          if (frameBgHexSrc.toLowerCase() == 'transparent') {
            bgColor = Colors.transparent;
          } else {
            final hex = frameBgHexSrc.replaceAll('#', '');
            bgColor = Color(int.parse('FF$hex', radix: 16));
          }
        } catch (_) {}
        if (bgColor != Colors.transparent) {
          if (frameCornerRadiusPx > 0) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(frameOffsetX, frameOffsetY,
                    outW + leftPx + rightPx, outH + topPx + bottomPx),
                Radius.circular(frameCornerRadiusPx),
              ),
              Paint()..color = bgColor,
            );
          } else {
            canvas.drawRect(
              Rect.fromLTWH(frameOffsetX, frameOffsetY, outW + leftPx + rightPx,
                  outH + topPx + bottomPx),
              Paint()..color = bgColor,
            );
          }
        }
      }

      // ── 4b. 绘制图片（抖动模糊 + 颜色效果）────────────────────────────────────
      final destRect = Rect.fromLTWH(
          frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH);
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
        final shakeRect1 = Rect.fromLTWH(frameOffsetX + leftPx + dx1,
            frameOffsetY + topPx + dy1, outW, outH);
        final shakeRect2 = Rect.fromLTWH(frameOffsetX + leftPx + dx2,
            frameOffsetY + topPx + dy2, outW, outH);
        // ── FIX: 绘制抖动重影效果（2层半透明位移叠加，模拟手持拍立得的运动模糊）──
        canvas.drawImageRect(
          sourceImage,
          cropRect,
          shakeRect1,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Color.fromARGB(ghostAlpha1, 255, 255, 255)
            ..blendMode = BlendMode.modulate,
        );
        canvas.drawImageRect(
          sourceImage,
          cropRect,
          shakeRect2,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Color.fromARGB(ghostAlpha2, 255, 255, 255)
            ..blendMode = BlendMode.modulate,
        );
      }

      // 鱼眼模式：先 save/clipPath 圆形区域，使图片只在圆内绘制（与 GL shader 一致）
      // GPU 已处理时，原生 shader 已在圆外输出纯黑，无需 Flutter Canvas 再做圆形裁切
      if (fisheyeMode && !gpuProcessed) {
        canvas.save();
        final fisheyeCenter = Offset(
          frameOffsetX + leftPx + outW / 2,
          frameOffsetY + topPx + outH / 2,
        );
        // 与原生 shader 对齐：有效圆半径缩小到 90%，让圆边界更明显。
        final fisheyeRadius = math.min(outW, outH) / 2 * 0.90;
        final fisheyeClipPath = Path()
          ..addOval(
              Rect.fromCircle(center: fisheyeCenter, radius: fisheyeRadius));
        canvas.clipPath(fisheyeClipPath);
      }

      // 主图（正常绘制）
      // 注意：GPU 管线已在步骤 2c 完成（gpuProcessed=true），srcImage 已是处理后图像。
      // 此处直接绘制 srcImage，不再重复调用 processWithGpu（之前的重复调用导致成片无画面）。
      if (gpuProcessed || renderParams == null) {
        // GPU 已处理（或无渲染参数）：直接绘制，不叠加 colorMatrix
        canvas.drawImageRect(
          sourceImage,
          cropRect,
          destRect,
          Paint()..filterQuality = FilterQuality.high,
        );
      } else {
        // Dart 降级管线：通过 colorMatrix 叠加基础色彩效果
        final colorMatrix = buildColorMatrix(renderParams);
        canvas.drawImageRect(
          sourceImage,
          cropRect,
          destRect,
          Paint()
            ..filterQuality = FilterQuality.high
            ..colorFilter = ColorFilter.matrix(colorMatrix),
        );
      }

      // 鱼眼模式：恢复 canvas（圆形 clip 结束，仅 Dart 降级时执行）
      if (fisheyeMode && !gpuProcessed) {
        canvas.restore();
      }

      // ── 4c. 暗角 ──────────────────────────────────────────────────────────────
      // GPU 成片管线已包含 Vignette Pass，仅在 Dart 降级时由 Canvas 补充
      if (!gpuProcessed &&
          renderParams != null &&
          renderParams.effectiveVignette > 0.01) {
        _drawVignette(canvas, frameOffsetX + leftPx, frameOffsetY + topPx, outW,
            outH, renderParams.effectiveVignette);
      }

      // ── 4c3. 胶片颗粒感（grain）+ 数字噪点（noise）──────────────────────────
      // GPU 成片管线已包含 Film Grain + Digital Noise Pass，仅在 Dart 降级时由 Canvas 补充
      if (!gpuProcessed &&
          renderParams != null &&
          (renderParams.effectiveGrain > 0.01 ||
              renderParams.noiseAmount > 0.001)) {
        _drawFilmGrain(canvas, frameOffsetX + leftPx, frameOffsetY + topPx,
            outW, outH, renderParams.effectiveGrain,
            noiseAmount: renderParams.noiseAmount);
      }

      // ── 4c2. 内嵌阴影（拟物相纸厚度感）──────────────────────────────────────
      if (frameOpt != null && frameOpt.innerShadow) {
        _drawInnerShadow(
            canvas, frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH);
      }

      // ── 4d. 漏光效果 ──────────────────────────────────────────────────────────
      final lightLeakStrength = frameOpt?.lightLeak ?? 0.0;
      if (lightLeakStrength > 0.01) {
        _drawLightLeak(canvas, frameOffsetX + leftPx, frameOffsetY + topPx,
            outW, outH, lightLeakStrength);
      }

      // ── 4e. 色差（Chromatic Aberration）──────────────────────────────────────
      // GPU 成片管线已包含 Chromatic Aberration Pass，仅在 Dart 降级时由 Canvas 补充
      if (!gpuProcessed &&
          renderParams != null &&
          renderParams.policy.enableChromaticAberration &&
          renderParams.effectiveChromaticAberration > 0.001) {
        _drawChromaticAberration(
          canvas,
          sourceImage,
          cropRect,
          destRect,
          renderParams.effectiveChromaticAberration,
          renderParams,
        );
      }

      // ── 4e2. Bloom / 柔焦光晕 ────────────────────────────────────────────────
      // GPU 成片管线已包含 Bloom Pass，仅在 Dart 降级时由 Canvas 补充
      if (!gpuProcessed &&
          renderParams != null &&
          renderParams.policy.enableBloom &&
          (renderParams.effectiveBloom > 0.01 ||
              renderParams.effectiveSoftFocus > 0.01)) {
        _drawBloom(
          canvas,
          sourceImage,
          cropRect,
          destRect,
          renderParams.effectiveBloom,
          renderParams.effectiveSoftFocus,
          renderParams,
        );
      }

      // ── 4e3. 鱼眼四角黑色遮罩 ────────────────────────────────────────────
      // GPU 已处理时，原生 shader 已在圆外输出纯黑，无需 Flutter Canvas 再绘制遮罩
      // Dart 降级时仍由 _drawFisheyeMask 补充（与预览层 _FisheyeCirclePainter 对齐）
      if (fisheyeMode && !gpuProcessed) {
        _drawFisheyeMask(
            canvas, frameOffsetX + leftPx, frameOffsetY + topPx, outW, outH);
      }

      // ── 4f. 相框纹理 PNG 叠加 ──────────────────────────────────────────────────
      if (frameOpt != null &&
          resolvedAsset != null &&
          resolvedAsset.isNotEmpty) {
        try {
          final frameImg = await _getFrameTexture(
            resolvedAsset,
            canvasW.toInt(),
            canvasH.toInt(),
          );
          canvas.drawImageRect(
            frameImg,
            Rect.fromLTWH(
                0, 0, frameImg.width.toDouble(), frameImg.height.toDouble()),
            Rect.fromLTWH(0, 0, canvasW, canvasH),
            Paint()..filterQuality = FilterQuality.high,
          );
          debugPrint(
              '[CapturePipeline] frame texture applied: $resolvedAsset (ratio=$selectedRatioId)');
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
          hasFrame: frameOpt != null,
        );
      }

      // ── 5. 光栅化并输出 ────────────────────────────────────────────────────────
      final picture = recorder.endRecording();
      final outputImage =
          await picture.toImage(canvasW.toInt(), canvasH.toInt());

      //      // ── 5b. 根据设备方向旋转图片 ────────────────────────────────────
      // GPU 路径默认已处理方向，但部分机型仍会出现横竖错向。
      // 采用自适应策略：仅当当前输出朝向与设备朝向不一致时补旋转，避免双重旋转。
      int effectiveQuarter = deviceQuarter;
      if (gpuProcessed) {
        final expectedLandscape = deviceQuarter == 1 || deviceQuarter == 3;
        final currentLandscape = canvasW >= canvasH;
        effectiveQuarter =
            (expectedLandscape == currentLandscape) ? 0 : deviceQuarter;
      }
      ui.Image finalImage = outputImage;
      if (effectiveQuarter != 0) {
        // quarter 定义：1=左横屏(逆时针), 3=右横屏(顺时针)。
        // 这里需要把图像旋回“自然正向”，横屏角度不能直接用 quarter*pi/2。
        final rotAngle = switch (effectiveQuarter) {
          1 => -math.pi / 2,
          2 => math.pi,
          3 => math.pi / 2,
          _ => 0.0,
        };
        final isLandscape = effectiveQuarter == 1 || effectiveQuarter == 3;
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
        debugPrint(
            '[CapturePipeline] rotated: quarter=$effectiveQuarter, ${rotW.toInt()}x${rotH.toInt()}');
      }

      // ── 5b-2. 应用 GL Shader 中缺失的效果 (已移动到 Canvas 绘制前) ────────────

      final byteData =
          await finalImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;

      final finalW = effectiveQuarter == 1 || effectiveQuarter == 3
          ? canvasH.toInt()
          : canvasW.toInt();
      final finalH = effectiveQuarter == 1 || effectiveQuarter == 3
          ? canvasW.toInt()
          : canvasH.toInt();

      final jpegBytes = await _encodeJpeg(
        byteData.buffer.asUint8List(),
        finalW,
        finalH,
        quality: jpegQuality,
      );
      if (gpuOutputPath != null) {
        try {
          File(gpuOutputPath).deleteSync();
        } catch (_) {}
      }
      debugPrint(
          '[CapturePipeline] output: ${finalW}x${finalH}, bytes=${jpegBytes.length}');
      return CaptureResult(
          bytes: jpegBytes, outputWidth: finalW, outputHeight: finalH);
    } catch (e, st) {
      debugPrint('[CapturePipeline] Error: $e\n$st');
      return null;
    }
  }

  // ── 比例裁剪（中心裁剪，保持目标宽高比）────────────────────────────────────────

  Rect _calcCropRect(
    double w,
    double h,
    String ratioId, {
    bool preferLandscapeOutput = false,
  }) {
    RatioDefinition? ratioOpt;
    if (ratioId.isNotEmpty) {
      try {
        ratioOpt = camera.modules.ratios.firstWhere((r) => r.id == ratioId);
      } catch (_) {}
    }
    ratioOpt ??=
        camera.modules.ratios.isNotEmpty ? camera.modules.ratios.first : null;

    if (ratioOpt == null) return Rect.fromLTWH(0, 0, w, h);

    var targetRatio = ratioOpt.width.toDouble() / ratioOpt.height.toDouble();
    if (preferLandscapeOutput && targetRatio != 1.0) {
      targetRatio = 1.0 / targetRatio;
    }
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

    debugPrint(
        '[CapturePipeline] ratio=${ratioOpt.label} targetRatio=$targetRatio srcRatio=$srcRatio crop=${cropW}x${cropH}@($cropX,$cropY)');
    return Rect.fromLTWH(cropX, cropY, cropW, cropH);
  }

  // ── 颜色矩阵（与预览一致）────────────────────────────────────────────────────

  static List<double> buildColorMatrix(PreviewRenderParams params) {
    var m = _identity();

    // 1. 曝光
    // `params.exposureOffset` already includes lens exposure in toJson(),
    // avoid double-applying lens gain on Dart fallback path.
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
      if (params.effectiveBlacks.abs() > 0.5 ||
          params.effectiveWhites.abs() > 0.5) {
        m = _multiply(
            m,
            _blacksWhitesMatrix(
                params.effectiveBlacks, params.effectiveWhites));
      }
    }
    // 5. 对比度
    if (params.policy.enableContrast) {
      m = _multiply(m, _contrastMatrix(params.effectiveContrast));
    }
    // 6. 高光/阴影
    if (params.policy.enableContrast) {
      if (params.effectiveHighlights.abs() > 0.5 ||
          params.effectiveShadows.abs() > 0.5) {
        m = _multiply(
            m,
            _highlightsShadowsMatrix(
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
    if (params.policy.enableSaturation &&
        params.effectiveVibrance.abs() > 0.5) {
      m = _multiply(m, _vibranceMatrix(params.effectiveVibrance));
    }
    // 10. 色彩偏移 (film color bias)
    if (params.effectiveColorBiasR.abs() > 0.005 ||
        params.effectiveColorBiasG.abs() > 0.005 ||
        params.effectiveColorBiasB.abs() > 0.005) {
      m = _multiply(
          m,
          _colorBiasMatrix(
            params.effectiveColorBiasR,
            params.effectiveColorBiasG,
            params.effectiveColorBiasB,
          ));
    }
    if (params.hasBwMixer) {
      final mixer = params.bwChannelMixer;
      m = _multiply(m, _bwChannelMixerMatrix(mixer[0], mixer[1], mixer[2]));
    }
    return m;
  }

  static List<double> _identity() => [
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ];

  static List<double> _exposureMatrix(double mul) => [
        mul,
        0,
        0,
        0,
        0,
        0,
        mul,
        0,
        0,
        0,
        0,
        0,
        mul,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ];

  static List<double> _temperatureMatrix(double temp) {
    final t = temp / 100.0;
    final rShift = t * 0.20;
    final bShift = -t * 0.20;
    return [
      1 + rShift,
      0,
      0,
      0,
      0,
      0,
      1.0,
      0,
      0,
      0,
      0,
      0,
      1 + bShift,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _contrastMatrix(double contrast) {
    final offset = 0.5 * (1 - contrast);
    return [
      contrast,
      0,
      0,
      0,
      offset * 255,
      0,
      contrast,
      0,
      0,
      offset * 255,
      0,
      0,
      contrast,
      0,
      offset * 255,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _saturationMatrix(double sat) {
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final sr = (1 - sat) * lr;
    final sg = (1 - sat) * lg;
    final sb = (1 - sat) * lb;
    return [
      sr + sat,
      sg,
      sb,
      0,
      0,
      sr,
      sg + sat,
      sb,
      0,
      0,
      sr,
      sg,
      sb + sat,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _multiply(List<double> a, List<double> b) {
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

  static List<double> _tintMatrix(double tint) {
    final t = tint / 100.0;
    final gShift = -t * 0.12;
    final rbShift = t * 0.06;
    return [
      1 + rbShift,
      0,
      0,
      0,
      0,
      0,
      1 + gShift,
      0,
      0,
      0,
      0,
      0,
      1 + rbShift,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _blacksWhitesMatrix(double blacks, double whites) {
    final blacksOffset = blacks / 100.0 * 20.0;
    final whitesScale = 1.0 + whites / 100.0 * 0.15;
    return [
      whitesScale,
      0,
      0,
      0,
      blacksOffset,
      0,
      whitesScale,
      0,
      0,
      blacksOffset,
      0,
      0,
      whitesScale,
      0,
      blacksOffset,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _highlightsShadowsMatrix(
      double highlights, double shadows) {
    final hScale = 1.0 + highlights / 100.0 * 0.12;
    final hOffset = -highlights / 100.0 * 0.12 * 191.0;
    final sScale = 1.0 - shadows / 100.0 * 0.08;
    final sOffset = shadows / 100.0 * 0.08 * 64.0 + shadows / 100.0 * 12.0;
    final scale = hScale * sScale;
    final offset = hOffset * sScale + sOffset;
    return [
      scale,
      0,
      0,
      0,
      offset,
      0,
      scale,
      0,
      0,
      offset,
      0,
      0,
      scale,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _clarityMatrix(double clarity) {
    final c = clarity / 100.0;
    final boost = 1.0 + c * 0.15;
    final offset = -c * 0.15 * 0.5 * 255;
    return [
      boost,
      0,
      0,
      0,
      offset,
      0,
      boost,
      0,
      0,
      offset,
      0,
      0,
      boost,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _vibranceMatrix(double vibrance) {
    final v = vibrance / 100.0 * 0.6;
    final sat = 1.0 + v;
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final sr = (1 - sat) * lr;
    final sg = (1 - sat) * lg;
    final sb = (1 - sat) * lb;
    return [
      sr + sat,
      sg,
      sb,
      0,
      0,
      sr,
      sg + sat,
      sb,
      0,
      0,
      sr,
      sg,
      sb + sat,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _colorBiasMatrix(double r, double g, double b) {
    return [
      1,
      0,
      0,
      0,
      r * 30.0,
      0,
      1,
      0,
      0,
      g * 30.0,
      0,
      0,
      1,
      0,
      b * 30.0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static List<double> _bwChannelMixerMatrix(double r, double g, double b) {
    return [
      r,
      g,
      b,
      0,
      0,
      r,
      g,
      b,
      0,
      0,
      r,
      g,
      b,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
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
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [shadowColor, Colors.transparent],
        ).createShader(Rect.fromLTWH(ox, oy, w, sw)),
    );
    canvas.drawRect(
      Rect.fromLTWH(ox, oy + h - sw, w, sw),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [shadowColor, Colors.transparent],
        ).createShader(Rect.fromLTWH(ox, oy + h - sw, w, sw)),
    );
    canvas.drawRect(
      Rect.fromLTWH(ox, oy, sw, h),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [shadowColor, Colors.transparent],
        ).createShader(Rect.fromLTWH(ox, oy, sw, h)),
    );
    canvas.drawRect(
      Rect.fromLTWH(ox + w - sw, oy, sw, h),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [shadowColor, Colors.transparent],
        ).createShader(Rect.fromLTWH(ox + w - sw, oy, sw, h)),
    );
  }

  // ── 胶片颗粒感（Film Grain）────────────────────────────────────────────────
  /// 优化版：使用两个 Path（亮颗粒 / 暗颗粒）批量绘制，减少 draw call 从 O(N) 降到 O(2)
  void _drawFilmGrain(
      Canvas canvas, double ox, double oy, double w, double h, double strength,
      {double noiseAmount = 0.0}) {
    final rng = math.Random(DateTime.now().microsecondsSinceEpoch);
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
        brightPath
            .addOval(Rect.fromCircle(center: Offset(px, py), radius: size));
      } else {
        darkPath.addOval(Rect.fromCircle(center: Offset(px, py), radius: size));
      }
    }

    final brightness = (strength * 60).clamp(20, 80).toInt();
    final noiseAlpha = (noiseAmount * 80).clamp(0, 100).toInt();
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

    if (noiseAmount > 0.001) {
      canvas.drawPath(
        darkPath,
        Paint()
          ..color = Color.fromARGB(noiseAlpha, 0, 0, 0)
          ..blendMode = BlendMode.overlay,
      );
    }
  }

  void _drawVignette(Canvas canvas, double ox, double oy, double w, double h,
      double strength) {
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

  void _drawLightLeak(Canvas canvas, double ox, double oy, double w, double h,
      double strength) {
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
      do {
        idx2 = rng.nextInt(4);
      } while (corners[idx2] == selectedCorners[0]);
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

  // ── 色差（Chromatic Aberration）──────────────────────────────────────────────────
  /// 与预览层 _ChromaticAberrationLayer 对齐：
  /// R 通道向左偏移，B 通道向右偏移，两者都以 alpha 叠加在主图上
  void _drawChromaticAberration(
    Canvas canvas,
    ui.Image srcImage,
    Rect cropRect,
    Rect destRect,
    double strength,
    PreviewRenderParams renderParams,
  ) {
    final offset = strength * 6.0; // 与预览层一致：6px per unit
    final alpha = (strength / 0.1 * 0.25).clamp(0.0, 0.25); // 与预览层一致
    final colorMatrix = buildColorMatrix(renderParams);
    // 红通道向左偏移移
    final redRect = Rect.fromLTWH(
      destRect.left - offset,
      destRect.top,
      destRect.width,
      destRect.height,
    );
    canvas.drawImageRect(
      srcImage,
      cropRect,
      redRect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = ColorFilter.matrix([
          colorMatrix[0],
          colorMatrix[1],
          colorMatrix[2],
          colorMatrix[3],
          colorMatrix[4],
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          alpha,
          0,
        ]),
    );

    // 蓝通道向右偏移
    final blueRect = Rect.fromLTWH(
      destRect.left + offset,
      destRect.top,
      destRect.width,
      destRect.height,
    );
    canvas.drawImageRect(
      srcImage,
      cropRect,
      blueRect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = ColorFilter.matrix([
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          colorMatrix[10],
          colorMatrix[11],
          colorMatrix[12],
          colorMatrix[13],
          colorMatrix[14],
          0,
          0,
          0,
          alpha,
          0,
        ]),
    );
  }

  // ── Bloom / 柔焦光晕 ───────────────────────────────────────────────────────────────
  /// 与预览层 _BloomLayer 对齐：模糊图像叠加暖色调半透明层
  /// 注意：Flutter Canvas 没有内置高斯模糊，用多层偏移叠加模拟柔焦效果
  void _drawBloom(
    Canvas canvas,
    ui.Image srcImage,
    Rect cropRect,
    Rect destRect,
    double bloomStrength,
    double softFocus,
    PreviewRenderParams renderParams,
  ) {
    final opacity = (bloomStrength * 0.25 + softFocus * 0.15).clamp(0.0, 0.5);
    if (opacity < 0.01) return;

    // 模拟模糊：用 4 个小偏移叠加模拟柔焦效果
    final blurRadius = (bloomStrength * 12 + softFocus * 20).clamp(0.0, 30.0);
    final shifts = [
      Offset(-blurRadius * 0.5, -blurRadius * 0.5),
      Offset(blurRadius * 0.5, -blurRadius * 0.5),
      Offset(-blurRadius * 0.5, blurRadius * 0.5),
      Offset(blurRadius * 0.5, blurRadius * 0.5),
    ];
    final layerAlpha = (opacity / shifts.length).clamp(0.0, 1.0);

    for (final shift in shifts) {
      final shiftedRect = Rect.fromLTWH(
        destRect.left + shift.dx,
        destRect.top + shift.dy,
        destRect.width,
        destRect.height,
      );
      canvas.drawImageRect(
        srcImage,
        cropRect,
        shiftedRect,
        Paint()
          ..filterQuality = FilterQuality.low
          ..colorFilter = ColorFilter.matrix([
            1.2,
            0,
            0,
            0,
            0,
            0,
            1.1,
            0,
            0,
            0,
            0,
            0,
            0.9,
            0,
            0,
            0,
            0,
            0,
            layerAlpha,
            0,
          ]),
      );
    }
  }

  // ── 鱼眼四角黑色遮罩 ───────────────────────────────────────────────────────────────
  /// 与预览层 _FisheyeCirclePainter 对齐：
  /// 在图片区域的圆形以外绘制纯黑遮罩，模拟鱼眼镜头的圆形画面效果
  void _drawFisheyeMask(
    Canvas canvas,
    double ox,
    double oy,
    double w,
    double h,
  ) {
    final center = Offset(ox + w / 2, oy + h / 2);
    // 与 shader 保持一致
    final radius = math.min(w, h) / 2 * 0.90;
    // 用 Path evenOdd 填充规则：矩形 - 圆形 = 四角黑色区域
    final maskPath = Path()
      ..addRect(Rect.fromLTWH(ox, oy, w, h))
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(maskPath, Paint()..color = Colors.black);
  }

  // ── 水印（绘制在图片区域内）──────────────────────────────────────────────────

  void _drawWatermark(
    Canvas canvas,
    double ox,
    double oy,
    double w,
    double h,
    String watermarkId, {
    String? colorOverride,
    String? positionOverride,
    String? sizeOverride,
    String? directionOverride,
    String? styleOverride,
    bool hasFrame = false,
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
      case 'small':
        baseFontSize = w * 0.028;
        break;
      case 'medium':
        baseFontSize = w * 0.038;
        break;
      case 'large':
        baseFontSize = w * 0.055;
        break;
      default:
        baseFontSize = w * 0.038;
    }
    final fontSize = baseFontSize.clamp(12.0, 120.0);

    final isVertical = (directionOverride ?? 'horizontal') == 'vertical';
    final position = positionOverride ?? wmOpt.position ?? 'bottom_right';
    // 有相框时增大 margin，让水印更靠照片内部，避免视觉上贴近相框边缘
    final margin = w * (hasFrame ? 0.08 : 0.04);

    final fontFamily = styleDef.fontFamily ?? wmOpt.fontFamily;
    final letterSpacing = styleDef.letterSpacing;
    final fontWeight = styleDef.fontWeight;

    if (isVertical) {
      final verticalText = text.split('').join('\n');
      final textPainter = TextPainter(
        text: TextSpan(
          text: verticalText,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontWeight: fontWeight,
          ),
        ),
        textAlign: TextAlign.center,
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

  //  // ── RGBA bytes → JPEG bytes（使用 compute() 在独立 Isolate 中编码，不阻塞 UI 线程）─────
  Future<Uint8List> _encodeJpeg(Uint8List rgba, int w, int h,
      {int quality = 82}) {
    return compute(_encodeJpegIsolate, _JpegEncodeParams(rgba, w, h, quality));
  }

  // ── 双重曝光图层合成 ──────────────────────────────────────────────────────────────
  /// 将两张照片合成为双重曝光效果。
  /// - [firstImagePath] 第一张照片的本地文件路径（已经过后处理）
  /// - [secondImageBytes] 第二张照片的 JPEG 字节（已经过后处理）
  /// - [blend] 第一张权重 0.3~0.7，默认 0.5
  /// 合成算法：两张各降曝光后用 BlendMode.screen 叠加，最接近胶片双重曝光效果
  static Future<Uint8List?> blendDoubleExposure({
    required String firstImagePath,
    required Uint8List secondImageBytes,
    double blend = 0.5,
  }) async {
    try {
      // Best-practice: use native blend pipeline on mobile platforms
      // to avoid large pixel transfers/loops in Dart isolate.
      if (Platform.isAndroid || Platform.isIOS) {
        final native = await _channel.invokeMethod<Map>(
          "blendDoubleExposure",
          {
            "firstImagePath": firstImagePath,
            "secondImageBytes": secondImageBytes,
            "blend": blend.clamp(0.0, 1.0),
            "jpegQuality": 90,
          },
        );
        final nativePath = native?["filePath"] as String?;
        if (nativePath != null && nativePath.isNotEmpty) {
          final bytes = await File(nativePath).readAsBytes();
          try {
            File(nativePath).deleteSync();
          } catch (_) {}
          debugPrint(
              '[DoubleExp] Native blend complete: ${bytes.length} bytes');
          return bytes;
        }
      }

      // Non-mobile fallback.
      final firstBytes = await File(firstImagePath).readAsBytes();
      final result = await compute(
        _blendDoubleExposureIsolate,
        _DoubleExposureBlendParams(
          firstBytes: firstBytes,
          secondBytes: secondImageBytes,
          blend: blend.clamp(0.0, 1.0),
          quality: 90,
        ),
      );
      if (result == null) return null;
      debugPrint(
          '[DoubleExp] Dart blend fallback complete: ${result.length} bytes');
      return result;
    } catch (e, st) {
      debugPrint('[DoubleExp] blendDoubleExposure error: $e\n$st');
      return null;
    }
  }
}

// ── Isolate 顶层函数（必须是顶层函数，不能是类方法）────────────────────────────────────
class _DoubleExposureBlendParams {
  final Uint8List firstBytes;
  final Uint8List secondBytes;
  final double blend;
  final int quality;
  const _DoubleExposureBlendParams({
    required this.firstBytes,
    required this.secondBytes,
    required this.blend,
    required this.quality,
  });
}

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

Uint8List? _blendDoubleExposureIsolate(_DoubleExposureBlendParams p) {
  final first = img_lib.decodeImage(p.firstBytes);
  final second = img_lib.decodeImage(p.secondBytes);
  if (first == null || second == null) return null;

  final w = first.width;
  final h = first.height;
  if (w <= 0 || h <= 0) return null;

  final secondAligned = (second.width == w && second.height == h)
      ? second
      : img_lib.copyResize(
          second,
          width: w,
          height: h,
          interpolation: img_lib.Interpolation.linear,
        );

  final out = img_lib.Image(width: w, height: h, numChannels: 4);
  final firstWeight = p.blend.clamp(0.0, 1.0);
  final secondWeight = (1.0 - firstWeight).clamp(0.0, 1.0);

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final c1 = first.getPixel(x, y);
      final c2 = secondAligned.getPixel(x, y);

      final r1 = c1.r.toDouble() * firstWeight;
      final g1 = c1.g.toDouble() * firstWeight;
      final b1 = c1.b.toDouble() * firstWeight;

      final r2 = c2.r.toDouble() * secondWeight;
      final g2 = c2.g.toDouble() * secondWeight;
      final b2 = c2.b.toDouble() * secondWeight;

      final r = _screenBlendByte(r1, r2);
      final g = _screenBlendByte(g1, g2);
      final b = _screenBlendByte(b1, b2);
      final a = math.max(c1.a.toDouble(), c2.a.toDouble()).clamp(0.0, 255.0);

      out.setPixelRgba(x, y, r, g, b, a);
    }
  }

  final jpegBytes = img_lib.encodeJpg(out, quality: p.quality);
  return Uint8List.fromList(jpegBytes);
}

double _screenBlendByte(double lhs, double rhs) {
  final l = lhs.clamp(0.0, 255.0);
  final r = rhs.clamp(0.0, 255.0);
  return (255.0 - ((255.0 - l) * (255.0 - r) / 255.0)).clamp(0.0, 255.0);
}
