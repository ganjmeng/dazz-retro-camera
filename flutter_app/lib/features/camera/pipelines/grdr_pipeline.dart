import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show applyIsolateEffects;

/// GRD-R 专属成片管线
/// 对标 GRDRShader.metal（12 Pass），补全预览中被 SIMPLIFIED 注释掉的 3 个 Pass
/// GRD-R（Ricoh GR Digital）高对比度街拍风格，高光滚落较轻
Future<ui.Image> processGRDR(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 3: Highlight Rolloff ──────────────────────────────────────────────
  // GRD-R defaultLook: highlightRolloff=0.10（较轻，保留数码锐利感）
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 9: Sensor Non-uniformity ─────────────────────────────────────────
  // GRD-R defaultLook: centerGain=0.02, edgeFalloff=0.05, cornerWarmShift=0.0
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 8: Skin Protection ────────────────────────────────────────────────
  // GRD-R defaultLook: skinHueProtect=1.0, skinSatProtect=0.94
  final isoParams = IsolateParams.from(params);
  if (isoParams.skinHueProtect) {
    srcImage = await applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
