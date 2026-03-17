import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show _applyIsolateEffects;

/// BW Classic 专属成片管线
/// 对标 BWClassicShader.metal（12 Pass），补全预览中被 SIMPLIFIED 注释掉的 2 个 Pass
/// BW Classic（黑白经典）无肤色保护（黑白模式），化学不规则感较强
Future<ui.Image> processBWClassic(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 4: Highlight Rolloff ──────────────────────────────────────────────
  // BWClassic defaultLook: highlightRolloff=0.18（胶片黑白高光保护最强）
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 6: Sensor Non-uniformity ─────────────────────────────────────────
  // BWClassic defaultLook: centerGain=0.05, edgeFalloff=0.12（最强边缘衰减，模拟老镜头）
  // BWClassic cornerWarmShift=0.0（黑白模式无色偏意义）
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: 0.0, // 黑白模式无角落色偏
    );
  }

  // ── Pass 7: Development Softness ──────────────────────────────────────────
  // BWClassic defaultLook: developmentSoftness=0.025
  if (params.developmentSoftness > 0.001) {
    srcImage = await drawDevelopmentSoftness(srcImage, params.developmentSoftness);
  }

  // ── Pass 8: Chemical Irregularity ─────────────────────────────────────────
  // BWClassic defaultLook: chemicalIrregularity=0.018（黑白胶片化学不均匀感）
  // 注意：BWClassic 无肤色保护（黑白模式下无意义），直接调用 drawChemicalIrregularity
  if (params.chemicalIrregularity > 0.001) {
    srcImage = await drawChemicalIrregularity(srcImage, params.chemicalIrregularity);
  }

  return srcImage;
}
