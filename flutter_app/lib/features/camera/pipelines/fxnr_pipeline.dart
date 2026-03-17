import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show _applyIsolateEffects;

/// FXN-R 专属成片管线
/// 对标 CameraShaders.metal（通用 CCD Shader），补全 FXN-R defaultLook 中对应的 SIMPLIFIED Pass
/// FXN-R（富士 X 系列数码相机）偏冷、高锐度、有胶片感
Future<ui.Image> processFXNR(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 2.5: Highlight Rolloff ────────────────────────────────────────────
  // FXN-R defaultLook: highlightRolloff=0.16
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 6: Sensor Non-uniformity + Corner Warm Shift ─────────────────────
  // FXN-R defaultLook: centerGain=0.01, edgeFalloff=0.035, cornerWarmShift=-0.015（偏冷青）
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 7: Development Softness ──────────────────────────────────────────
  // FXN-R defaultLook: developmentSoftness=0.02
  if (params.developmentSoftness > 0.001) {
    srcImage = await drawDevelopmentSoftness(srcImage, params.developmentSoftness);
  }

  // ── Pass 8 + 9: Skin Protection + Chemical Irregularity ───────────────────
  // FXN-R defaultLook: skinHueProtect=1.0, skinSatProtect=0.96, skinLumaSoften=0.03, skinRedLimit=1.04
  // FXN-R defaultLook: chemicalIrregularity=0.01
  final isoParams = IsolateParams.from(params);
  if (isoParams.chemicalIrregularity > 0.001 || isoParams.skinHueProtect) {
    srcImage = await _applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
