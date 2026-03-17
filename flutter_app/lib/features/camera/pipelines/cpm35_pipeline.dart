import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show _applyIsolateEffects;

/// CPM35 专属成片管线
/// 对标 CPM35Shader.metal（16 Pass），补全预览中被 SIMPLIFIED 注释掉的 4 个 Pass
Future<ui.Image> processCPM35(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 7: Highlight Rolloff ──────────────────────────────────────────────
  // CPM35 defaultLook: highlightRolloff=0.14
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 12: Sensor Non-uniformity + Corner Warm Shift ────────────────────
  // CPM35 defaultLook: centerGain=0.015, edgeFalloff=0.03, cornerWarmShift=0.022
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 13: Development Softness ─────────────────────────────────────────
  // CPM35 defaultLook: developmentSoftness=0.028
  if (params.developmentSoftness > 0.001) {
    srcImage = await drawDevelopmentSoftness(srcImage, params.developmentSoftness);
  }

  // ── Pass 11: Skin Protection + Chemical Irregularity ──────────────────────
  // CPM35 defaultLook: skinSatProtect=0.90, skinRedLimit=1.05
  // CPM35 defaultLook: chemicalIrregularity=0.02
  final isoParams = IsolateParams.from(params);
  if (isoParams.chemicalIrregularity > 0.001 || isoParams.skinHueProtect) {
    srcImage = await _applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
