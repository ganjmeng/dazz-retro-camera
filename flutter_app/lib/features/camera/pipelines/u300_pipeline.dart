import 'dart:ui' as ui;
import './pipeline_utils.dart';
import '../capture_pipeline_ext.dart';
import '../preview_renderer.dart';
import './instc_pipeline.dart' show _applyIsolateEffects;

/// U300 专属成片管线
/// 对标 U300Shader.metal（14 Pass），补全预览中被 SIMPLIFIED 注释掉的 5 个 Pass
/// U300（Olympus μ-300）消费级数码相机，暖色调，边缘衰减明显
Future<ui.Image> processU300(ui.Image srcImage, PreviewRenderParams params) async {
  // ── Pass 2: Highlight Rolloff ──────────────────────────────────────────────
  // U300 defaultLook: highlightRolloff=0.15
  if (params.highlightRolloff > 0.001) {
    srcImage = await drawHighlightRolloff(srcImage, params.highlightRolloff);
  }

  // ── Pass 8: Sensor Non-uniformity ─────────────────────────────────────────
  // U300 defaultLook: centerGain=0.06, edgeFalloff=0.15（最强边缘衰减，模拟廉价镜头）
  // U300 cornerWarmShift=0.025（角落偏暖，模拟廉价镜头的色差）
  if (params.centerGain > 0.001 || params.edgeFalloff > 0.001) {
    srcImage = await drawSensorNonUniformity(
      srcImage,
      params.centerGain,
      params.edgeFalloff,
      cornerWarmShift: params.defaultLook.cornerWarmShift,
    );
  }

  // ── Pass 9: Development Softness ──────────────────────────────────────────
  // U300 defaultLook: developmentSoftness=0.03
  if (params.developmentSoftness > 0.001) {
    srcImage = await drawDevelopmentSoftness(srcImage, params.developmentSoftness);
  }

  // ── Pass 7 + 10: Skin Protection + Chemical Irregularity ──────────────────
  // U300 defaultLook: skinHueProtect=1.0, skinSatProtect=0.92
  // U300 defaultLook: chemicalIrregularity=0.025（较强，模拟廉价传感器噪声）
  final isoParams = IsolateParams.from(params);
  if (isoParams.chemicalIrregularity > 0.001 || isoParams.skinHueProtect) {
    srcImage = await _applyIsolateEffects(srcImage, isoParams);
  }

  return srcImage;
}
