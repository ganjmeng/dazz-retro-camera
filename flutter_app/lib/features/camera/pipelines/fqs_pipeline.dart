import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show applyIsolateEffects;

/// FQS 专属成片管线
/// 对标 FQSShader.metal（15 Pass），补全预览中被 SIMPLIFIED 注释掉的 4 个 Pass
/// FQS（Fujifilm Instax Square）无相纸纹理，化学不规则感较强
Future<ui.Image> processFQS(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 1.5: Development Softness ────────────────────────────────────────
  // FQS defaultLook: developmentSoftness=0.032（FQS 显影柔化最强）
  if (params.developmentSoftness > 0.001) {
    srcImage = await drawDevelopmentSoftness(srcImage, params.developmentSoftness);
  }

  // ── Pass 6.5: Highlight Rolloff ────────────────────────────────────────────
  // FQS defaultLook: highlightRolloff=0.12
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 11.5: Sensor Non-uniformity ──────────────────────────────────────
  // FQS defaultLook: centerGain=0.018, edgeFalloff=0.04, cornerWarmShift=-0.008
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 7: Skin Protection + Chemical Irregularity ───────────────────────
  // FQS 无 paperTexture（FQS 相纸表面光滑，无明显纤维纹理）
  // FQS chemicalIrregularity=0.022（较强，FQS 化学显影不均匀感明显）
  final isoParams = IsolateParams.from(params);
  if (isoParams.chemicalIrregularity > 0.001 || isoParams.skinHueProtect) {
    srcImage = await applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
