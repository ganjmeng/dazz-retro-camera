import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';

/// InstC / Inst S 专属成片管线
/// 对标 InstCShader.metal（18 Pass），补全预览中被 SIMPLIFIED 注释掉的 7 个 Pass
Future<ui.Image> processInstC(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 7: Highlight Rolloff ──────────────────────────────────────────────
  // InstC defaultLook: highlightRolloff=0.20
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 11: Edge Falloff + Center Gain + Corner Warm Shift ───────────────
  // InstC defaultLook: centerGain=0.02, edgeFalloff=0.05, cornerWarmShift=0.02
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 15: Development Softness ─────────────────────────────────────────
  // InstC defaultLook: developmentSoftness=0.03
  if (params.developmentSoftness > 0.001) {
    srcImage = await drawDevelopmentSoftness(srcImage, params.developmentSoftness);
  }

  // ── Pass 16 + 12 + 13: Chemical Irregularity + Fine Grain + Paper Texture ─
  // (Isolate 并行处理，一次遍历完成所有像素级效果)
  final isoParams = IsolateParams.from(params);
  if (isoParams.chemicalIrregularity > 0.001 ||
      isoParams.paperTexture > 0.001 ||
      isoParams.skinHueProtect) {
    srcImage = await _applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}

/// 通用 Isolate 并行处理入口（所有专属管线共用）
Future<ui.Image> _applyIsolateEffects(ui.Image image, IsolateParams isoParams) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) return image;

  final pixels = byteData.buffer.asUint8List();
  final width = image.width;
  final height = image.height;
  final numIsolates = 4;
  final rowsPerIsolate = (height / numIsolates).ceil();

  final futures = <Future<Uint8List>>[];
  for (int i = 0; i < numIsolates; i++) {
    final startRow = i * rowsPerIsolate;
    final endRow = (startRow + rowsPerIsolate).clamp(0, height);
    if (startRow >= height) break;
    final chunk = pixels.sublist(startRow * width * 4, endRow * width * 4);
    futures.add(compute(
      processImageChunk,
      IsolatePayload(chunk, 0, endRow - startRow, width, endRow - startRow, isoParams),
    ));
  }

  final results = await Future.wait(futures);
  final output = Uint8List(pixels.length);
  int offset = 0;
  for (final result in results) {
    output.setRange(offset, offset + result.length, result);
    offset += result.length;
  }

  final codec = await ui.ImmutableBuffer.fromUint8List(output);
  final descriptor = await ui.ImageDescriptor.raw(
    codec,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final frameCodec = await descriptor.instantiateCodec();
  final frame = await frameCodec.getNextFrame();
  return frame.image;
}
